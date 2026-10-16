"""Continuous synchronisation of a remote managed agent platform into this one.

A tenant connects a provider (Anthropic Managed Agents, the OpenAI Agents API)
with its own credential. This module keeps ``public.remote_agents`` (migration
071) equal to what that provider reports, and tells the dashboard when it
changes:

* **Poll.** Every ``CONNECTOR_SYNC_INTERVAL_SECONDS`` (default 30, minimum 5)
  each connected connector with an adapter gets a full paginated listing. The
  listing is diffed against the stored rows: new and changed items are
  upserted, unchanged ones have ``last_seen_at`` stamped, and items absent from
  a *complete* listing of their kind get ``gone_at`` -- never a silent delete.
  A Postgres advisory lock per connector means one replica polls a connector at
  a time, and the persisted ``next_poll_at`` lets the other replicas skip it.
  429 and 5xx back off exponentially with jitter and honour ``retry-after``.
* **Stream.** For Anthropic sessions that are running, the session's SSE event
  stream is attached (at most ``STREAMS_PER_TENANT`` per tenant). A
  status-changing event re-fetches the session, so a state change lands in
  seconds rather than at the next poll. Streams reconnect with backoff and stop
  when the session is no longer running.
* **Webhook.** ``POST /api/connectors/claude/webhook`` (routers/connectors.py)
  re-fetches the resource an Anthropic webhook names. Optional: Anthropic only
  delivers to a public HTTPS endpoint, which a local cluster does not have.
* **Fan-out.** Every change is published on ``EVENTS``, an in-process pub/sub
  keyed by tenant, served as SSE by ``GET /api/connectors/stream``.

Live mode only. Fixture mode (no database) never starts the loop and never
writes here; the standing rule is that live mode serves no fake data, and this
module only ever stores what a provider returned.

Adding a provider is local: implement ``ProviderAdapter`` and register it in
``ADAPTERS``.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from typing import Any, AsyncIterator, Awaitable, Callable, Iterable

import httpx

import connector_credentials

logger = logging.getLogger("signalloom.remote_agent_sync")

ANTHROPIC_API = "https://api.anthropic.com"
OPENAI_API = "https://api.openai.com"
ANTHROPIC_HEADERS = {"anthropic-version": "2023-06-01", "anthropic-beta": "managed-agents-2026-04-01"}
OPENAI_AGENTS_BETA = {"OpenAI-Beta": "agents=v1"}

DEFAULT_INTERVAL_SECONDS = 30.0
MIN_INTERVAL_SECONDS = 5.0
MAX_BACKOFF_SECONDS = 900.0
PAGE_LIMIT = 100
# A listing longer than this is reported incomplete rather than paged forever;
# an incomplete listing never marks anything gone.
MAX_PAGES = 50
STREAMS_PER_TENANT = 8
UPSTREAM_TIMEOUT = 10.0

# Anthropic session states in which the session's event stream is worth holding.
ANTHROPIC_LIVE_SESSION_STATES = frozenset({"running", "rescheduling"})
# Session events that change what the session's row would say.
ANTHROPIC_STATUS_EVENTS = frozenset({
    "session.status_running", "session.status_idle", "session.status_terminated",
    "session.status_rescheduled", "session.updated", "session.error", "session.deleted",
})


WORKSPACE_REQUIRED_CODE = "workspace_required"
WORKSPACE_REQUIRED_MESSAGE = ("This Anthropic key is organisation-scoped: enter the Workspace ID "
                              "(Console → Settings → Workspaces) and test again.")


def anthropic_headers(key: str, workspace_id: str | None = None) -> dict[str, str]:
    """Headers for every Anthropic call; ``anthropic-workspace-id`` only when a workspace is known.

    An organisation-scoped key (not bound to one workspace) is refused with a
    400 unless the request names the workspace (verified live 2026-10-16).
    """
    headers = {"x-api-key": key, **ANTHROPIC_HEADERS}
    if workspace_id and workspace_id.strip():
        headers["anthropic-workspace-id"] = workspace_id.strip()
    return headers


def anthropic_workspace_required(status: int | None, body: str) -> bool:
    """True for Anthropic's 400 "This API key is not scoped to a workspace ..."."""
    if status != 400:
        return False
    text = body.lower()
    return "not scoped to a workspace" in text or "anthropic-workspace-id" in text


def sync_interval_seconds() -> float:
    raw = os.environ.get("CONNECTOR_SYNC_INTERVAL_SECONDS", "")
    try:
        value = float(raw) if raw else DEFAULT_INTERVAL_SECONDS
    except ValueError:
        logger.warning("CONNECTOR_SYNC_INTERVAL_SECONDS=%r is not a number; using %s", raw, DEFAULT_INTERVAL_SECONDS)
        value = DEFAULT_INTERVAL_SECONDS
    return max(MIN_INTERVAL_SECONDS, value)


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_ts(value: Any) -> datetime | None:
    """An ISO-8601 string or a unix timestamp from a provider; None if absent or unreadable."""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return datetime.fromtimestamp(value, tz=timezone.utc)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    return None


def _json(value: Any) -> Any:
    return json.loads(value) if isinstance(value, str) else value


# ---------------------------------------------------------------------------
# Provider adapters
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class RemoteItem:
    """One thing a provider reported, reduced to the columns of remote_agents."""
    external_id: str
    kind: str
    name: str | None
    model: str | None
    status: str | None
    version: str | None
    external_updated_at: datetime | None
    raw: dict[str, Any]

    def comparable(self) -> tuple[Any, ...]:
        return (self.kind, self.name, self.model, self.status, self.version, self.external_updated_at)


@dataclass
class CallLog:
    """One upstream request, for the scan log. Never carries a credential."""
    endpoint: str
    status_code: int | None
    duration_ms: int
    count: int | None = None
    error: str | None = None


class ProviderError(Exception):
    def __init__(self, message: str, *, status: int | None = None, retry_after: float | None = None,
                 code: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after
        self.code = code

    @property
    def retryable(self) -> bool:
        return self.status is None or self.status == 429 or self.status >= 500


@dataclass
class Listing:
    items: list[RemoteItem] = field(default_factory=list)
    # Kinds whose every page was read. Only these may mark anything gone.
    complete_kinds: set[str] = field(default_factory=set)
    attempted_kinds: list[str] = field(default_factory=list)
    calls: list[CallLog] = field(default_factory=list)
    errors: list[ProviderError] = field(default_factory=list)


def _retry_after(resp: httpx.Response, now: Callable[[], datetime]) -> float | None:
    raw = resp.headers.get("retry-after")
    if not raw:
        return None
    try:
        return max(0.0, float(raw))
    except ValueError:
        pass
    try:
        when = parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return max(0.0, (when - now()).total_seconds())


async def _get_json(
    http: httpx.AsyncClient, url: str, headers: dict[str, str], params: dict[str, Any] | None,
    calls: list[CallLog], now: Callable[[], datetime], *, allow_404: bool = False,
) -> Any:
    started = time.monotonic()
    try:
        resp = await http.get(url, headers=headers, params=params)
    except httpx.HTTPError as exc:
        calls.append(CallLog(f"GET {url}", None, int((time.monotonic() - started) * 1000), error=type(exc).__name__))
        raise ProviderError(f"GET {url} failed before a response ({type(exc).__name__})") from None
    elapsed = int((time.monotonic() - started) * 1000)
    if allow_404 and resp.status_code == 404:
        calls.append(CallLog(f"GET {url}", 404, elapsed))
        return None
    if anthropic_workspace_required(resp.status_code, resp.text):
        calls.append(CallLog(f"GET {url}", 400, elapsed, error=WORKSPACE_REQUIRED_MESSAGE))
        raise ProviderError(WORKSPACE_REQUIRED_MESSAGE, status=400, code=WORKSPACE_REQUIRED_CODE)
    if resp.status_code != 200:
        calls.append(CallLog(f"GET {url}", resp.status_code, elapsed, error=f"HTTP {resp.status_code}"))
        raise ProviderError(f"GET {url} answered HTTP {resp.status_code}", status=resp.status_code,
                            retry_after=_retry_after(resp, now))
    try:
        payload = resp.json()
    except ValueError:
        calls.append(CallLog(f"GET {url}", 200, elapsed, error="invalid JSON"))
        raise ProviderError(f"GET {url} answered 200 with a body that is not JSON", status=200) from None
    calls.append(CallLog(f"GET {url}", 200, elapsed,
                         count=len(payload["data"]) if isinstance(payload, dict) and isinstance(payload.get("data"), list) else None))
    return payload


class ProviderAdapter:
    """What a provider must offer to be synchronised. Streams and webhooks are optional."""

    provider_id: str = ""
    display_name: str = ""
    supports_stream: bool = False

    def credential(self, creds: dict[str, str]) -> str | None:
        raise NotImplementedError

    async def list_inventory(self, http: httpx.AsyncClient, creds: dict[str, str],
                             now: Callable[[], datetime]) -> Listing:
        raise NotImplementedError

    async def fetch_one(self, http: httpx.AsyncClient, creds: dict[str, str], kind: str, external_id: str,
                        now: Callable[[], datetime]) -> RemoteItem | None:
        """The item as the provider reports it now; None when the provider says it does not exist."""
        raise NotImplementedError

    def wants_stream(self, item: RemoteItem) -> bool:
        return False

    async def stream_status_events(self, http: httpx.AsyncClient, creds: dict[str, str],
                                   external_id: str) -> AsyncIterator[str]:
        """Yield the type of every state-changing event on the item's stream."""
        raise NotImplementedError
        yield ""  # pragma: no cover


async def _paginate(
    http: httpx.AsyncClient, url: str, headers: dict[str, str], base_params: dict[str, Any],
    calls: list[CallLog], now: Callable[[], datetime], next_params: Callable[[dict[str, Any]], dict[str, Any] | None],
) -> tuple[list[dict[str, Any]], bool]:
    """Every item across every page; ``complete`` False when MAX_PAGES was reached first."""
    items: list[dict[str, Any]] = []
    params = dict(base_params)
    for _ in range(MAX_PAGES):
        payload = await _get_json(http, url, headers, params, calls, now)
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list):
            raise ProviderError(f"GET {url} answered 200 without a data list", status=200)
        items.extend(d for d in data if isinstance(d, dict) and d.get("id"))
        follow = next_params(payload)
        if follow is None:
            return items, True
        params = {**base_params, **follow}
    return items, False


def _pick(obj: dict[str, Any], keys: Iterable[str]) -> dict[str, Any]:
    return {k: obj[k] for k in keys if k in obj}


def _model_id(model: Any) -> str | None:
    if isinstance(model, str):
        return model or None
    if isinstance(model, dict):
        mid = model.get("id")
        return mid if isinstance(mid, str) and mid else None
    return None


class AnthropicAdapter(ProviderAdapter):
    """Anthropic Managed Agents: ``GET /v1/agents`` and ``GET /v1/sessions``, cursor paginated.

    Field names are those of the official SDK (``anthropic`` 1.15.0,
    ``BetaManagedAgentsAgent`` / ``BetaManagedAgentsSession``). An agent has no
    status field; an archived agent (``archived_at`` set) reports ``archived``
    and any other agent reports NULL, i.e. "the provider did not say".
    """

    provider_id = "claude"
    display_name = "Anthropic Claude"
    supports_stream = True

    _AGENT_RAW = ("id", "type", "name", "description", "version", "created_at", "updated_at", "archived_at")
    _SESSION_RAW = ("id", "type", "title", "status", "environment_id", "deployment_id",
                    "created_at", "updated_at", "archived_at")

    def credential(self, creds: dict[str, str]) -> str | None:
        return creds.get("api_key") or None

    def _headers(self, key: str, creds: dict[str, str] | None = None) -> dict[str, str]:
        return anthropic_headers(key, (creds or {}).get("workspace_id"))

    def _agent(self, a: dict[str, Any]) -> RemoteItem:
        raw = _pick(a, self._AGENT_RAW)
        raw["model"] = _model_id(a.get("model"))
        version = a.get("version")
        return RemoteItem(
            external_id=str(a["id"]), kind="agent", name=a.get("name") or None, model=raw["model"],
            status="archived" if a.get("archived_at") else None,
            version=str(version) if version is not None else None,
            external_updated_at=_parse_ts(a.get("updated_at")), raw=raw,
        )

    def _session(self, s: dict[str, Any]) -> RemoteItem:
        raw = _pick(s, self._SESSION_RAW)
        agent = s.get("agent") if isinstance(s.get("agent"), dict) else {}
        model = _model_id(agent.get("model"))
        raw["agent"] = {"id": agent.get("id"), "name": agent.get("name"), "version": agent.get("version"), "model": model}
        version = agent.get("version")
        return RemoteItem(
            external_id=str(s["id"]), kind="session", name=s.get("title") or None, model=model,
            status=s.get("status") if isinstance(s.get("status"), str) else None,
            version=str(version) if version is not None else None,
            external_updated_at=_parse_ts(s.get("updated_at")), raw=raw,
        )

    async def list_inventory(self, http, creds, now) -> Listing:
        key = self.credential(creds)
        listing = Listing()
        if not key:
            listing.errors.append(ProviderError("No Anthropic API key is stored for this connector; no request was made.", status=401))
            return listing
        headers = self._headers(key, creds)

        def follow(payload: dict[str, Any]) -> dict[str, Any] | None:
            nxt = payload.get("next_page")
            return {"page": nxt} if nxt else None

        for kind, path, params, convert in (
            ("agent", "/v1/agents", {"limit": PAGE_LIMIT, "include_archived": "true"}, self._agent),
            ("session", "/v1/sessions", {"limit": PAGE_LIMIT}, self._session),
        ):
            listing.attempted_kinds.append(kind)
            try:
                raw_items, complete = await _paginate(http, f"{ANTHROPIC_API}{path}", headers, params,
                                                      listing.calls, now, follow)
            except ProviderError as exc:
                listing.errors.append(exc)
                continue
            listing.items.extend(convert(i) for i in raw_items)
            if complete:
                listing.complete_kinds.add(kind)
            else:
                listing.errors.append(ProviderError(f"Listing Anthropic {kind}s stopped after {MAX_PAGES} pages; "
                                                    "nothing was marked gone.", status=200))
        return listing

    async def fetch_one(self, http, creds, kind, external_id, now) -> RemoteItem | None:
        key = self.credential(creds)
        if not key:
            raise ProviderError("No Anthropic API key is stored for this connector.", status=401)
        path = {"agent": "/v1/agents/", "session": "/v1/sessions/"}.get(kind)
        if path is None:
            raise ProviderError(f"Anthropic has no '{kind}' resource to fetch", status=400)
        payload = await _get_json(http, f"{ANTHROPIC_API}{path}{external_id}", self._headers(key, creds), None, [], now,
                                  allow_404=True)
        if payload is None:
            return None
        if not isinstance(payload, dict) or not payload.get("id"):
            raise ProviderError(f"Anthropic answered 200 for {kind} {external_id} without an id", status=200)
        return self._agent(payload) if kind == "agent" else self._session(payload)

    def wants_stream(self, item: RemoteItem) -> bool:
        return item.kind == "session" and item.status in ANTHROPIC_LIVE_SESSION_STATES

    async def stream_status_events(self, http, creds, external_id) -> AsyncIterator[str]:
        key = self.credential(creds)
        if not key:
            raise ProviderError("No Anthropic API key is stored for this connector.", status=401)
        url = f"{ANTHROPIC_API}/v1/sessions/{external_id}/events/stream"
        headers = {**self._headers(key, creds), "accept": "text/event-stream"}
        async with http.stream("GET", url, headers=headers, timeout=httpx.Timeout(UPSTREAM_TIMEOUT, read=None)) as resp:
            if resp.status_code != 200:
                body = (await resp.aread()).decode("utf-8", "replace")
                if anthropic_workspace_required(resp.status_code, body):
                    raise ProviderError(WORKSPACE_REQUIRED_MESSAGE, status=400, code=WORKSPACE_REQUIRED_CODE)
                raise ProviderError(f"GET {url} answered HTTP {resp.status_code}", status=resp.status_code)
            async for event_type in parse_sse_types(resp.aiter_lines()):
                if event_type in ANTHROPIC_STATUS_EVENTS:
                    yield event_type


class OpenAIAdapter(ProviderAdapter):
    """The OpenAI Agents API (beta): ``GET /v1/agents/sessions``, ``after``/``has_more`` paginated.

    Verified against developers.openai.com (2026-10-16): the Agents API guide
    "Find sessions" lists sessions with ``limit``/``order``/``after`` and the
    ``OpenAI-Beta: agents=v1`` header; the session object carries ``id``,
    ``status`` (idle | in_progress | requires_action | failed), ``created_at``
    and ``last_active_at`` (unix seconds) and ``agent{id, model, ...}``. It has
    no name. The Assistants API was shut down on 2026-08-26, and no documented
    endpoint lists Agent Builder workflows, so neither is synchronised.
    """

    provider_id = "openai"
    display_name = "OpenAI"

    _SESSION_RAW = ("id", "object", "status", "created_at", "last_active_at", "error")

    def credential(self, creds: dict[str, str]) -> str | None:
        return creds.get("api_key") or creds.get("admin_api_key") or None

    def _headers(self, key: str) -> dict[str, str]:
        return {"Authorization": f"Bearer {key}", **OPENAI_AGENTS_BETA}

    def _session(self, s: dict[str, Any]) -> RemoteItem:
        raw = _pick(s, self._SESSION_RAW)
        agent = s.get("agent") if isinstance(s.get("agent"), dict) else {}
        model = _model_id(agent.get("model"))
        raw["agent"] = {"id": agent.get("id"), "model": model}
        return RemoteItem(
            external_id=str(s["id"]), kind="session", name=None, model=model,
            status=s.get("status") if isinstance(s.get("status"), str) else None, version=None,
            external_updated_at=_parse_ts(s.get("last_active_at")), raw=raw,
        )

    async def list_inventory(self, http, creds, now) -> Listing:
        key = self.credential(creds)
        listing = Listing(attempted_kinds=["session"])
        if not key:
            listing.errors.append(ProviderError("No OpenAI API key is stored for this connector; no request was made.", status=401))
            return listing

        def follow(payload: dict[str, Any]) -> dict[str, Any] | None:
            if payload.get("has_more") and payload.get("last_id"):
                return {"after": payload["last_id"]}
            return None

        try:
            raw_items, complete = await _paginate(
                http, f"{OPENAI_API}/v1/agents/sessions", self._headers(key),
                {"limit": PAGE_LIMIT, "order": "desc"}, listing.calls, now, follow,
            )
        except ProviderError as exc:
            listing.errors.append(exc)
            return listing
        listing.items.extend(self._session(i) for i in raw_items)
        if complete:
            listing.complete_kinds.add("session")
        else:
            listing.errors.append(ProviderError(f"Listing OpenAI sessions stopped after {MAX_PAGES} pages; "
                                                "nothing was marked gone.", status=200))
        return listing

    async def fetch_one(self, http, creds, kind, external_id, now) -> RemoteItem | None:
        key = self.credential(creds)
        if not key:
            raise ProviderError("No OpenAI API key is stored for this connector.", status=401)
        if kind != "session":
            raise ProviderError(f"OpenAI has no '{kind}' resource to fetch", status=400)
        payload = await _get_json(http, f"{OPENAI_API}/v1/agents/sessions/{external_id}", self._headers(key), None,
                                  [], now, allow_404=True)
        if payload is None:
            return None
        if not isinstance(payload, dict) or not payload.get("id"):
            raise ProviderError(f"OpenAI answered 200 for session {external_id} without an id", status=200)
        return self._session(payload)


ADAPTERS: dict[str, ProviderAdapter] = {a.provider_id: a for a in (AnthropicAdapter(), OpenAIAdapter())}


async def parse_sse_types(lines: AsyncIterator[str]) -> AsyncIterator[str]:
    """The ``type`` of each SSE event: the JSON ``data`` field's ``type``, else the ``event:`` name."""
    event_name: str | None = None
    data_lines: list[str] = []
    async for line in lines:
        if line == "":
            if data_lines or event_name:
                event_type = event_name
                try:
                    payload = json.loads("\n".join(data_lines)) if data_lines else None
                except ValueError:
                    payload = None
                if isinstance(payload, dict) and isinstance(payload.get("type"), str):
                    event_type = payload["type"]
                if event_type:
                    yield event_type
            event_name, data_lines = None, []
            continue
        if line.startswith(":"):
            continue
        name, _, value = line.partition(":")
        value = value[1:] if value.startswith(" ") else value
        if name == "event":
            event_name = value
        elif name == "data":
            data_lines.append(value)


# ---------------------------------------------------------------------------
# Change fan-out: in-process pub/sub keyed by tenant
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class StreamEvent:
    id: int
    event: str
    data: dict[str, Any]

    def encode(self) -> str:
        return f"id: {self.id}\nevent: {self.event}\ndata: {json.dumps(self.data, separators=(',', ':'))}\n\n"


class _Subscription:
    def __init__(self, bus: "RemoteAgentEventBus", tenant_id: str, queue: asyncio.Queue[StreamEvent | None]) -> None:
        self._bus, self.tenant_id, self.queue = bus, tenant_id, queue

    def close(self) -> None:
        self._bus._unsubscribe(self)


class RemoteAgentEventBus:
    """Per-tenant pub/sub with a small replay ring. A subscriber only ever sees its own tenant.

    A subscriber whose queue fills is dropped (its stream ends) rather than
    blocking the publisher; the client reconnects with Last-Event-ID or refetches.
    """

    def __init__(self, ring_size: int = 256, queue_size: int = 512) -> None:
        self._seq = 0
        self._rings: dict[str, deque[StreamEvent]] = {}
        self._subs: dict[str, set[_Subscription]] = {}
        self._ring_size, self._queue_size = ring_size, queue_size

    def publish(self, tenant_id: str, event: str, data: dict[str, Any]) -> StreamEvent:
        self._seq += 1
        item = StreamEvent(self._seq, event, data)
        self._rings.setdefault(tenant_id, deque(maxlen=self._ring_size)).append(item)
        for sub in list(self._subs.get(tenant_id, ())):
            try:
                sub.queue.put_nowait(item)
            except asyncio.QueueFull:
                self._unsubscribe(sub)
                sub.queue = asyncio.Queue(maxsize=1)
                sub.queue.put_nowait(None)
        return item

    def subscribe(self, tenant_id: str, last_event_id: str | None = None) -> tuple[_Subscription, list[StreamEvent], bool]:
        """(subscription, events to replay, replay_complete).

        ``replay_complete`` is False when Last-Event-ID is older than the ring
        (or unparseable): the client must refetch, it cannot catch up from here.
        """
        queue: asyncio.Queue[StreamEvent | None] = asyncio.Queue(maxsize=self._queue_size)
        sub = _Subscription(self, tenant_id, queue)
        self._subs.setdefault(tenant_id, set()).add(sub)
        if not last_event_id:
            return sub, [], True
        try:
            last = int(last_event_id)
        except ValueError:
            return sub, [], False
        ring = list(self._rings.get(tenant_id, ()))
        replay = [e for e in ring if e.id > last]
        # Complete only when nothing between ``last`` and the ring's oldest entry
        # could have been evicted. Ids are global across tenants, so a gap in this
        # tenant's ids is normal; eviction is detectable only by the ring having filled.
        evicted = len(ring) == self._ring_size and ring and ring[0].id > last + 1
        return sub, replay, not evicted and last <= self._seq

    def _unsubscribe(self, sub: _Subscription) -> None:
        subs = self._subs.get(sub.tenant_id)
        if subs is not None:
            subs.discard(sub)
            if not subs:
                self._subs.pop(sub.tenant_id, None)

    def subscriber_count(self, tenant_id: str) -> int:
        return len(self._subs.get(tenant_id, ()))

    def reset(self) -> None:
        self._seq = 0
        self._rings.clear()
        self._subs.clear()


EVENTS = RemoteAgentEventBus()

HEARTBEAT_SECONDS = 15.0
SSE_RETRY_MS = 5000


async def sse_frames(
    bus: RemoteAgentEventBus, tenant_id: str, last_event_id: str | None,
    is_disconnected: Callable[[], Awaitable[bool]], *, heartbeat: float = HEARTBEAT_SECONDS,
    max_events: int | None = None,
) -> AsyncIterator[str]:
    """The text of ``GET /api/connectors/stream`` for one tenant, frame by frame."""
    sub, replay, complete = bus.subscribe(tenant_id, last_event_id)
    sent = 0
    try:
        yield f"retry: {SSE_RETRY_MS}\n\n"
        if not complete:
            yield "event: stream.reset\ndata: {}\n\n"
        for item in replay:
            yield item.encode()
            sent += 1
            if max_events is not None and sent >= max_events:
                return
        while True:
            if await is_disconnected():
                return
            try:
                item = await asyncio.wait_for(sub.queue.get(), timeout=heartbeat)
            except asyncio.TimeoutError:
                yield ": heartbeat\n\n"
                continue
            if item is None:
                return
            yield item.encode()
            sent += 1
            if max_events is not None and sent >= max_events:
                return
    finally:
        sub.close()


# ---------------------------------------------------------------------------
# Persistence: public.remote_agents and public.remote_agent_sync_state
# ---------------------------------------------------------------------------
# Every statement is tagged ``/* remote_agent_store:<op> */`` and, except the
# scheduler's ``due`` enumeration and the advisory lock, scoped by
# ``tenant_id = $1`` (tests/remote_agent_store_fake.py rejects any that is not).

_RA = "public.remote_agents"
_RA_COLS = ("external_id, kind, name, model, status, version, external_updated_at, "
            "first_seen_at, last_seen_at, last_changed_at, gone_at, claimed_agent_id, claimed_at")
RA_COLUMNS = _RA_COLS  # the wire columns, for statements issued outside this module

# The scheduler's view across tenants: which connectors to poll. It reads only
# identifiers; every statement for an individual connector is tenant-scoped.
SQL_DUE = (
    "/* remote_agent_store:due */ SELECT tenant_id, connector_id, provider_id FROM public.tenant_connectors "
    "WHERE status = 'connected' AND credentials_ciphertext IS NOT NULL AND provider_id = ANY($1::text[]) "
    "ORDER BY tenant_id, connector_id"
)
def with_connector_workspace(creds: dict[str, str], connector: Any) -> dict[str, str]:
    """``creds`` plus the connector metadata's ``workspace_id`` when the credentials carry none."""
    if creds.get("workspace_id"):
        return creds
    try:
        metadata = _json(connector["metadata"]) or {}
    except (KeyError, TypeError, ValueError):
        return creds
    workspace = metadata.get("workspace_id") if isinstance(metadata, dict) else None
    return {**creds, "workspace_id": workspace} if isinstance(workspace, str) and workspace.strip() else creds


SQL_CONNECTOR = (
    "/* remote_agent_store:connector */ SELECT connector_id, provider_id, status, credentials_ciphertext, metadata "
    "FROM public.tenant_connectors WHERE tenant_id = $1 AND (connector_id = $2 OR provider_id = $2) "
    "ORDER BY (connector_id = $2) DESC LIMIT 1"
)
SQL_EXISTING = f"/* remote_agent_store:existing */ SELECT {_RA_COLS} FROM {_RA} WHERE tenant_id = $1 AND connector_id = $2"
SQL_EXISTING_ONE = (
    f"/* remote_agent_store:existing_one */ SELECT {_RA_COLS} FROM {_RA} "
    "WHERE tenant_id = $1 AND connector_id = $2 AND external_id = $3"
)
SQL_UPSERT = (
    f"/* remote_agent_store:upsert */ INSERT INTO {_RA} (tenant_id, connector_id, provider_id, external_id, kind, "
    "name, model, status, version, external_updated_at, first_seen_at, last_seen_at, last_changed_at, gone_at, raw) "
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11, $11, NULL, $12::jsonb) "
    "ON CONFLICT (tenant_id, connector_id, external_id) DO UPDATE SET kind = EXCLUDED.kind, name = EXCLUDED.name, "
    "model = EXCLUDED.model, status = EXCLUDED.status, version = EXCLUDED.version, "
    "external_updated_at = EXCLUDED.external_updated_at, last_seen_at = EXCLUDED.last_seen_at, "
    "last_changed_at = EXCLUDED.last_changed_at, gone_at = NULL, raw = EXCLUDED.raw "
    f"WHERE {_RA}.tenant_id = $1 RETURNING {_RA_COLS}"
)
SQL_TOUCH = (
    f"/* remote_agent_store:touch */ UPDATE {_RA} SET last_seen_at = $3 "
    "WHERE tenant_id = $1 AND connector_id = $2 AND external_id = ANY($4::text[])"
)
SQL_MARK_GONE = (
    f"/* remote_agent_store:mark_gone */ UPDATE {_RA} SET gone_at = $3, last_changed_at = $3 "
    "WHERE tenant_id = $1 AND connector_id = $2 AND external_id = ANY($4::text[]) AND gone_at IS NULL "
    "RETURNING external_id, gone_at"
)
SQL_LIST = (
    f"/* remote_agent_store:list */ SELECT {_RA_COLS} FROM {_RA} WHERE tenant_id = $1 AND connector_id = $2 "
    "ORDER BY gone_at NULLS FIRST, kind, name NULLS LAST, external_id"
)
SQL_DISCOVERY = (
    "/* remote_agent_store:discovery */ SELECT ra.connector_id, ra.provider_id, ra.external_id, ra.kind, ra.name, "
    "ra.model, ra.status, ra.version, ra.external_updated_at, ra.first_seen_at, ra.last_seen_at, "
    "ra.claimed_agent_id "
    f"FROM {_RA} ra JOIN public.tenant_connectors tc "
    "ON tc.tenant_id = ra.tenant_id AND tc.connector_id = ra.connector_id "
    "WHERE ra.tenant_id = $1 AND ra.gone_at IS NULL AND tc.status = 'connected' "
    "ORDER BY ra.provider_id, ra.kind, ra.name NULLS LAST, ra.external_id"
)
_STATE_COLS = "provider_id, mode, last_poll_at, last_success_at, last_error, next_poll_at, consecutive_failures"
SQL_STATE_GET = (
    f"/* remote_agent_store:state_get */ SELECT {_STATE_COLS} FROM public.remote_agent_sync_state "
    "WHERE tenant_id = $1 AND connector_id = $2"
)
SQL_STATE_PUT = (
    "/* remote_agent_store:state_put */ INSERT INTO public.remote_agent_sync_state (tenant_id, connector_id, "
    "provider_id, mode, last_poll_at, last_success_at, last_error, next_poll_at, consecutive_failures, updated_at) "
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW()) ON CONFLICT (tenant_id, connector_id) DO UPDATE SET "
    "provider_id = EXCLUDED.provider_id, mode = EXCLUDED.mode, last_poll_at = EXCLUDED.last_poll_at, "
    "last_success_at = EXCLUDED.last_success_at, last_error = EXCLUDED.last_error, "
    "next_poll_at = EXCLUDED.next_poll_at, consecutive_failures = EXCLUDED.consecutive_failures, updated_at = NOW() "
    "WHERE public.remote_agent_sync_state.tenant_id = $1"
)
# Session-level advisory lock on (tenant, connector); held on one connection
# for the whole sync and released explicitly.
SQL_LOCK = "/* remote_agent_store:lock */ SELECT pg_try_advisory_lock(hashtextextended($1 || '/' || $2, 71))"
SQL_UNLOCK = "/* remote_agent_store:unlock */ SELECT pg_advisory_unlock(hashtextextended($1 || '/' || $2, 71))"


def agent_from_row(row: Any) -> dict[str, Any]:
    """The RemoteAgent wire shape."""
    return {
        "external_id": row["external_id"], "kind": row["kind"], "name": row["name"], "model": row["model"],
        "status": row["status"], "version": row["version"],
        "external_updated_at": iso(row["external_updated_at"]), "first_seen_at": iso(row["first_seen_at"]),
        "last_seen_at": iso(row["last_seen_at"]), "last_changed_at": iso(row["last_changed_at"]),
        "gone_at": iso(row["gone_at"]),
        "claimed_agent_id": str(row["claimed_agent_id"]) if row["claimed_agent_id"] is not None else None,
        "claimed_at": iso(row["claimed_at"]),
    }


def state_from_row(row: Any) -> dict[str, Any] | None:
    if row is None:
        return None
    return {
        "mode": row["mode"], "last_poll_at": iso(row["last_poll_at"]), "last_success_at": iso(row["last_success_at"]),
        "last_error": row["last_error"], "next_poll_at": iso(row["next_poll_at"]),
        "consecutive_failures": row["consecutive_failures"],
    }


async def list_remote_agents(pool: Any, tenant_id: str, connector_id: str) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    rows = await pool.fetch(SQL_LIST, tenant_id, connector_id)
    state = await pool.fetchrow(SQL_STATE_GET, tenant_id, connector_id)
    return [agent_from_row(r) for r in rows], state_from_row(state)


async def discovery_rows(pool: Any, tenant_id: str) -> list[Any]:
    return list(await pool.fetch(SQL_DISCOVERY, tenant_id))


# ---------------------------------------------------------------------------
# The sync engine
# ---------------------------------------------------------------------------

@dataclass
class SyncOutcome:
    """What one full sync observed and did."""
    provider_id: str
    connector_id: str
    listing: Listing
    counts: dict[str, int]
    upserted: int = 0
    unchanged: int = 0
    gone: int = 0
    skipped: str | None = None
    sync_state: dict[str, Any] | None = None

    @property
    def complete(self) -> bool:
        attempted = set(self.listing.attempted_kinds)
        return bool(attempted) and attempted <= self.listing.complete_kinds and not self.listing.errors

    @property
    def error(self) -> str | None:
        return " ".join(str(e) for e in self.listing.errors) or None


def _connector_key(tenant_id: str, connector_id: str) -> tuple[str, str]:
    return tenant_id, connector_id


class RemoteAgentSync:
    """Poll loop, stream manager and the single diff path every trigger goes through."""

    def __init__(
        self,
        pool_getter: Callable[[], Awaitable[Any]],
        *,
        adapters: dict[str, ProviderAdapter] | None = None,
        bus: RemoteAgentEventBus | None = None,
        interval: float | None = None,
        now: Callable[[], datetime] = utc_now,
        rng: Callable[[], float] = random.random,
        http_factory: Callable[[], httpx.AsyncClient] | None = None,
        tick_seconds: float = 1.0,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        streams_per_tenant: int = STREAMS_PER_TENANT,
        stream_reconnect_base: float = 1.0,
        stream_max_attempts: int = 6,
    ) -> None:
        self._pool_getter = pool_getter
        self.adapters = ADAPTERS if adapters is None else adapters
        self.bus = EVENTS if bus is None else bus
        self._interval = interval
        self.now = now
        self._rng = rng
        self._http_factory = http_factory or (lambda: httpx.AsyncClient(timeout=UPSTREAM_TIMEOUT))
        self._tick_seconds = tick_seconds
        self._sleep = sleep
        self._streams_per_tenant = streams_per_tenant
        self._stream_reconnect_base = stream_reconnect_base
        self._stream_max_attempts = stream_max_attempts
        self._due: dict[tuple[str, str], datetime] = {}
        self._loop_task: asyncio.Task[None] | None = None
        self._streams: dict[tuple[str, str, str], asyncio.Task[None]] = {}
        self._stopping = False

    @property
    def interval(self) -> float:
        return max(MIN_INTERVAL_SECONDS, self._interval) if self._interval is not None else sync_interval_seconds()

    # -- lifecycle ------------------------------------------------------------

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._stopping = False
            self._loop_task = asyncio.get_running_loop().create_task(self._run(), name="remote-agent-sync")

    async def stop(self) -> None:
        self._stopping = True
        tasks = [t for t in (self._loop_task, *self._streams.values()) if t is not None]
        for task in tasks:
            task.cancel()
        for task in tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._loop_task = None
        self._streams.clear()
        self._due.clear()
        self._stopping = False

    @property
    def running(self) -> bool:
        return self._loop_task is not None and not self._loop_task.done()

    def stream_keys(self) -> set[tuple[str, str, str]]:
        return {k for k, t in self._streams.items() if not t.done()}

    async def _run(self) -> None:
        while not self._stopping:
            pool = await self._pool_getter()
            if pool is None:
                # Fixture mode: nothing in live storage to keep in sync, and no
                # fixture is ever written here. Stop rather than spin.
                logger.info("remote agent sync: no database pool; not running")
                return
            try:
                await self.tick(pool)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("remote agent sync tick failed")
            await self._sleep(self._tick_seconds)

    async def tick(self, pool: Any) -> list[SyncOutcome]:
        """Sync every connector whose time has come. Returns what ran."""
        now = self.now()
        due_rows = await pool.fetch(SQL_DUE, sorted(self.adapters))
        seen: set[tuple[str, str]] = set()
        outcomes = []
        for row in due_rows:
            key = _connector_key(row["tenant_id"], row["connector_id"])
            seen.add(key)
            if self._due.get(key, now) > now:
                continue
            outcome = await self.sync_connector(pool, row["tenant_id"], row["connector_id"], scheduled=True)
            if outcome is not None:
                outcomes.append(outcome)
        for key in list(self._due):
            if key not in seen:
                self._due.pop(key, None)
        for skey, task in list(self._streams.items()):
            if (skey[0], skey[1]) not in seen:
                task.cancel()
                self._streams.pop(skey, None)
        return outcomes

    # -- one connector ---------------------------------------------------------

    def _backoff(self, failures: int, retry_after: float | None) -> float:
        delay = min(MAX_BACKOFF_SECONDS, self.interval * (2 ** failures))
        delay = delay * (0.5 + 0.5 * self._rng())  # jitter: half to full
        if retry_after is not None:
            delay = max(delay, retry_after)
        return delay

    async def sync_connector(
        self, pool: Any, tenant_id: str, connector_key: str, *, scheduled: bool = False,
        creds_override: dict[str, str] | None = None, connector: Any = None,
    ) -> SyncOutcome | None:
        """Full listing → diff → upsert / touch / mark gone → events. The one path for poll and scan.

        A scheduled sync takes the connector's advisory lock and skips when
        another replica holds it or has already polled within the interval. A
        manual scan does neither: the operator asked for it now, and passes the
        connector row it already read under the tenant's scope.
        """
        async with pool.acquire() as conn:
            if connector is None:
                connector = await conn.fetchrow(SQL_CONNECTOR, tenant_id, connector_key)
            if connector is None or connector["status"] != "connected":
                return None
            connector_id, provider_id = connector["connector_id"], connector["provider_id"]
            adapter = self.adapters.get(provider_id)
            if adapter is None:
                return None
            locked = False
            if scheduled:
                locked = bool(await conn.fetchval(SQL_LOCK, tenant_id, connector_id))
                if not locked:
                    self._due[_connector_key(tenant_id, connector_id)] = self.now() + timedelta(seconds=self.interval)
                    return None
            try:
                previous = await conn.fetchrow(SQL_STATE_GET, tenant_id, connector_id)
                if scheduled and previous is not None and previous["next_poll_at"] is not None:
                    next_at = _parse_ts(previous["next_poll_at"])
                    if next_at is not None and next_at > self.now() and _connector_key(tenant_id, connector_id) not in self._due:
                        # Another replica polled; follow its schedule.
                        self._due[_connector_key(tenant_id, connector_id)] = next_at
                        return None
                creds = (with_connector_workspace(creds_override, connector) if creds_override is not None
                         else self._open(tenant_id, connector))
                return await self._sync_locked(conn, tenant_id, connector_id, provider_id, adapter, creds, previous)
            finally:
                if locked:
                    await conn.fetchval(SQL_UNLOCK, tenant_id, connector_id)

    @staticmethod
    def _open(tenant_id: str, connector: Any) -> dict[str, str]:
        ciphertext = connector["credentials_ciphertext"]
        if not ciphertext:
            return with_connector_workspace({}, connector)
        try:
            creds = connector_credentials.open_credentials(tenant_id, connector["connector_id"], ciphertext)
        except (connector_credentials.CredentialStoreUnavailable, connector_credentials.CredentialDecryptError) as exc:
            logger.warning("remote agent sync: credentials for %s/%s cannot be opened: %s",
                           tenant_id, connector["connector_id"], exc)
            return {}
        return with_connector_workspace(creds, connector)

    async def _sync_locked(self, conn: Any, tenant_id: str, connector_id: str, provider_id: str,
                           adapter: ProviderAdapter, creds: dict[str, str], previous: Any) -> SyncOutcome:
        polled_at = self.now()
        async with self._http_factory() as http:
            listing = await adapter.list_inventory(http, creds, self.now)
        counts: dict[str, int] = {}
        for item in listing.items:
            counts[item.kind] = counts.get(item.kind, 0) + 1
        outcome = SyncOutcome(provider_id, connector_id, listing, counts)

        existing = {r["external_id"]: r for r in await conn.fetch(SQL_EXISTING, tenant_id, connector_id)}
        seen_at = self.now()
        unchanged_ids: list[str] = []
        listed_ids: set[str] = set()
        for item in listing.items:
            if item.external_id in listed_ids:
                continue
            listed_ids.add(item.external_id)
            row = existing.get(item.external_id)
            if row is not None and row["gone_at"] is None and _row_comparable(row) == item.comparable():
                unchanged_ids.append(item.external_id)
                continue
            await self._upsert(conn, tenant_id, connector_id, provider_id, item, seen_at)
            outcome.upserted += 1
        if unchanged_ids:
            await conn.execute(SQL_TOUCH, tenant_id, connector_id, seen_at, unchanged_ids)
        outcome.unchanged = len(unchanged_ids)

        vanished = [ext for ext, row in existing.items()
                    if ext not in listed_ids and row["gone_at"] is None and row["kind"] in listing.complete_kinds]
        if vanished:
            outcome.gone = await self._mark_gone(conn, tenant_id, connector_id, provider_id, vanished, seen_at)

        streams = 0
        if adapter.supports_stream:
            streams = self._ensure_streams(tenant_id, connector_id, adapter, creds,
                                           [i for i in listing.items if adapter.wants_stream(i)])
        outcome.sync_state = await self._record_state(conn, tenant_id, connector_id, provider_id, listing,
                                                      previous, polled_at, streams)
        return outcome

    async def _record_state(self, conn: Any, tenant_id: str, connector_id: str, provider_id: str,
                            listing: Listing, previous: Any, polled_at: datetime, streams: int) -> dict[str, Any]:
        last_success = _parse_ts(previous["last_success_at"]) if previous is not None else None
        failures = previous["consecutive_failures"] if previous is not None else 0
        if listing.errors:
            failures += 1
            retryable = [e for e in listing.errors if e.retryable]
            retry_after = max((e.retry_after for e in retryable if e.retry_after is not None), default=None)
            delay = self._backoff(failures, retry_after) if retryable else self.interval
            mode = "backoff" if retryable else ("poll+stream" if streams else "poll")
            last_error = " ".join(str(e) for e in listing.errors)
        else:
            failures = 0
            delay = self.interval
            mode = "poll+stream" if streams else "poll"
            last_error = None
            last_success = polled_at
        next_poll = polled_at + timedelta(seconds=delay)
        self._due[_connector_key(tenant_id, connector_id)] = next_poll
        await conn.execute(SQL_STATE_PUT, tenant_id, connector_id, provider_id, mode, polled_at, last_success,
                           last_error, next_poll, failures)
        state = {"mode": mode, "last_poll_at": iso(polled_at), "last_success_at": iso(last_success),
                 "last_error": last_error, "next_poll_at": iso(next_poll), "consecutive_failures": failures}
        self.bus.publish(tenant_id, "connector.sync_state",
                         {"provider_id": provider_id, "connector_id": connector_id, "sync_state": state})
        return state

    async def _upsert(self, conn: Any, tenant_id: str, connector_id: str, provider_id: str,
                      item: RemoteItem, at: datetime) -> dict[str, Any]:
        row = await conn.fetchrow(
            SQL_UPSERT, tenant_id, connector_id, provider_id, item.external_id, item.kind, item.name, item.model,
            item.status, item.version, item.external_updated_at, at, json.dumps(item.raw, default=str),
        )
        agent = agent_from_row(row)
        self.bus.publish(tenant_id, "remote_agent.upserted",
                         {"provider_id": provider_id, "connector_id": connector_id, "agent": agent})
        return agent

    async def _mark_gone(self, conn: Any, tenant_id: str, connector_id: str, provider_id: str,
                         external_ids: list[str], at: datetime) -> int:
        rows = await conn.fetch(SQL_MARK_GONE, tenant_id, connector_id, at, external_ids)
        for r in rows:
            self.bus.publish(tenant_id, "remote_agent.gone", {
                "provider_id": provider_id, "connector_id": connector_id,
                "external_id": r["external_id"], "gone_at": iso(r["gone_at"]),
            })
        return len(rows)

    # -- one item (stream and webhook) ----------------------------------------

    async def refresh_item(self, pool: Any, tenant_id: str, connector_key: str, kind: str, external_id: str,
                           *, deleted: bool = False) -> str:
        """Re-fetch one resource and apply it through the same diff rules.

        Returns 'upserted', 'unchanged', 'gone', 'absent' or 'skipped'.
        """
        async with pool.acquire() as conn:
            connector = await conn.fetchrow(SQL_CONNECTOR, tenant_id, connector_key)
            if connector is None or connector["status"] != "connected":
                return "skipped"
            connector_id, provider_id = connector["connector_id"], connector["provider_id"]
            adapter = self.adapters.get(provider_id)
            if adapter is None:
                return "skipped"
            creds = self._open(tenant_id, connector)
            item: RemoteItem | None = None
            if not deleted:
                async with self._http_factory() as http:
                    item = await adapter.fetch_one(http, creds, kind, external_id, self.now)
            row = await conn.fetchrow(SQL_EXISTING_ONE, tenant_id, connector_id, external_id)
            at = self.now()
            if item is None:
                if row is not None and row["gone_at"] is None:
                    await self._mark_gone(conn, tenant_id, connector_id, provider_id, [external_id], at)
                    return "gone"
                return "absent"
            if row is not None and row["gone_at"] is None and _row_comparable(row) == item.comparable():
                await conn.execute(SQL_TOUCH, tenant_id, connector_id, at, [external_id])
                result = "unchanged"
            else:
                await self._upsert(conn, tenant_id, connector_id, provider_id, item, at)
                result = "upserted"
            if adapter.supports_stream and adapter.wants_stream(item):
                self._ensure_streams(tenant_id, connector_id, adapter, creds, [item])
            return result

    # -- streams ---------------------------------------------------------------

    def _ensure_streams(self, tenant_id: str, connector_id: str, adapter: ProviderAdapter,
                        creds: dict[str, str], items: list[RemoteItem]) -> int:
        for key in [k for k, t in self._streams.items() if t.done()]:
            self._streams.pop(key, None)
        active = sum(1 for k in self._streams if k[0] == tenant_id)
        for item in items:
            key = (tenant_id, connector_id, item.external_id)
            if key in self._streams:
                continue
            if active >= self._streams_per_tenant:
                break
            self._streams[key] = asyncio.get_running_loop().create_task(
                self._follow_stream(tenant_id, connector_id, adapter, creds, item.external_id),
                name=f"remote-agent-stream:{tenant_id}:{item.external_id}",
            )
            active += 1
        return sum(1 for k in self._streams if k[0] == tenant_id and k[1] == connector_id)

    async def _follow_stream(self, tenant_id: str, connector_id: str, adapter: ProviderAdapter,
                             creds: dict[str, str], external_id: str) -> None:
        attempts = 0
        try:
            while not self._stopping and attempts < self._stream_max_attempts:
                try:
                    async with self._http_factory() as http:
                        async for event_type in adapter.stream_status_events(http, creds, external_id):
                            attempts = 0
                            pool = await self._pool_getter()
                            if pool is None:
                                return
                            await self.refresh_item(pool, tenant_id, connector_id, "session", external_id,
                                                    deleted=event_type == "session.deleted")
                except ProviderError as exc:
                    logger.info("stream for %s ended: %s", external_id, exc)
                    if exc.status is not None and 400 <= exc.status < 500 and exc.status != 429:
                        return
                except httpx.HTTPError as exc:
                    logger.info("stream for %s dropped: %s", external_id, type(exc).__name__)
                # The stream ended or dropped. Keep following only while the
                # session is still live, as the provider reports it now.
                pool = await self._pool_getter()
                if pool is None:
                    return
                try:
                    async with self._http_factory() as http:
                        item = await adapter.fetch_one(http, creds, "session", external_id, self.now)
                except ProviderError:
                    item = None
                    attempts += 1
                else:
                    await self.refresh_item(pool, tenant_id, connector_id, "session", external_id,
                                            deleted=item is None)
                    if item is None or not adapter.wants_stream(item):
                        return
                    attempts += 1
                delay = min(60.0, self._stream_reconnect_base * (2 ** attempts)) * (0.5 + 0.5 * self._rng())
                await self._sleep(delay)
        finally:
            key = (tenant_id, connector_id, external_id)
            if self._streams.get(key) is asyncio.current_task():
                self._streams.pop(key, None)


def _row_comparable(row: Any) -> tuple[Any, ...]:
    return (row["kind"], row["name"], row["model"], row["status"], row["version"],
            _parse_ts(row["external_updated_at"]))


async def _default_pool() -> Any:
    import api_compat
    return await api_compat._get_pool()


SYNC = RemoteAgentSync(_default_pool)
