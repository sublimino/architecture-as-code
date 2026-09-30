"""cAdvisor proxy poller and rate transformation engine (SLDC-P4-1).

Scrapes Kubelet cAdvisor proxy metrics every 2 seconds, calculates real-time
CPU consumption in millicores using rate differentials, and enforces the freeze
flatline invariant (delta CPU < 0.0001s outputs exact 0.000 mCPU).
"""
from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Optional, Tuple

import httpx
from fastapi import APIRouter, Depends, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from api_compat import APIError, authenticated_principal

logger = logging.getLogger("signalloom.cadvisor")

FREEZE_EPSILON = 0.0001  # 0.1 ms threshold for freeze flatline invariant
DEFAULT_POLL_INTERVAL = 2.0
#: No successful scrape for this long and the API answers 503, not old numbers.
DEFAULT_STALE_AFTER = 15.0
CONTAINER_TTL = 60.0


@dataclass
class MetricSample:
    timestamp: float
    cpu_seconds_total: float
    memory_rss_bytes: int
    throttle_count: int = 0


@dataclass
class AgentTelemetry:
    pod_name: str
    namespace: str
    #: ``None`` until two distinct cAdvisor samples exist: no rate is not a zero rate.
    millicores: Optional[float]
    memory_rss_mb: float
    status: str
    last_updated: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "pod_name": self.pod_name,
            "namespace": self.namespace,
            "millicores": self.millicores,
            "memory_rss_mb": round(self.memory_rss_mb, 2),
            "status": self.status,
            "last_updated": self.last_updated,
        }


def compute_cpu_rate(curr: MetricSample, prev: MetricSample, delta_sec: float) -> Optional[float]:
    """CPU in millicores, or ``None`` when the samples cannot honestly yield a rate.

    No elapsed time, a clock running backwards, or a non-finite or negative
    counter is "no reading", never 0.000 - a zero here is a freeze claim.
    """
    values = (curr.cpu_seconds_total, prev.cpu_seconds_total, delta_sec)
    if not all(math.isfinite(v) for v in values) or delta_sec <= 0.0:
        return None
    if curr.cpu_seconds_total < 0.0 or prev.cpu_seconds_total < 0.0:
        return None

    delta_cpu = curr.cpu_seconds_total - prev.cpu_seconds_total

    # Container restart / counter rollover protection
    if delta_cpu < 0.0:
        delta_cpu = curr.cpu_seconds_total

    # Freeze flatline invariant (delta CPU < 0.1ms returns exact 0.000 mCPU)
    if delta_cpu < FREEZE_EPSILON:
        return 0.0

    return (delta_cpu / delta_sec) * 1000.0


# Regex to parse Prometheus text format lines with labels
_METRIC_LINE_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)\{([^}]+)\}\s+([^\s]+)(?:\s+(\d+))?')
_LABEL_RE = re.compile(r'([a-zA-Z_:][a-zA-Z0-9_:]*)="([^"]*)"')


def parse_cadvisor_metrics(prom_text: str, now: Optional[float] = None) -> dict[Tuple[str, str, str], MetricSample]:
    """Parse raw Prometheus cAdvisor exposition text and filter agent containers.

    Raises ``ValueError`` when the body holds no sample line at all (an HTML
    error page, an empty body): that is a failed scrape, not an empty estate.
    Series without a usable CPU counter are dropped rather than defaulted to 0.
    """
    samples: dict[Tuple[str, str, str], dict[str, Any]] = {}
    now_ts = time.time() if now is None else now
    matched_any = False

    for line in prom_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        match = _METRIC_LINE_RE.match(line)
        if not match:
            continue
        matched_any = True

        metric_name, label_str, val_str, *ts_opt = match.groups()

        if metric_name not in (
            "container_cpu_usage_seconds_total",
            "container_memory_rss",
            "container_cpu_cfs_throttled_periods_total",
        ):
            continue

        # Extract labels
        labels = dict(_LABEL_RE.findall(label_str))
        container = labels.get("container", "")
        pod = labels.get("pod", "")
        namespace = labels.get("namespace", "")

        # Discard non-agent containers immediately
        if not container or container == "POD":
            continue

        is_target_ns = namespace == "fe-signalloom-agents"
        is_target_cont = container == "kusari-agent"
        if not is_target_ns and not is_target_cont:
            continue

        try:
            val = float(val_str)
        except ValueError:
            continue
        if not math.isfinite(val) or val < 0.0:
            continue

        ts = now_ts
        if ts_opt and ts_opt[0]:
            try:
                ts = float(ts_opt[0]) / 1000.0
            except ValueError:
                ts = now_ts

        key = (namespace, pod, container)
        if key not in samples:
            samples[key] = {
                "timestamp": ts,
                "cpu_seconds_total": None,
                "memory_rss_bytes": 0,
                "throttle_count": 0,
            }

        if metric_name == "container_cpu_usage_seconds_total":
            samples[key]["cpu_seconds_total"] = val
            samples[key]["timestamp"] = ts
        elif metric_name == "container_memory_rss":
            samples[key]["memory_rss_bytes"] = int(val)
        elif metric_name == "container_cpu_cfs_throttled_periods_total":
            samples[key]["throttle_count"] = int(val)

    if not matched_any:
        raise ValueError("cAdvisor body carried no Prometheus samples")

    result: dict[Tuple[str, str, str], MetricSample] = {}
    for key, data in samples.items():
        if data["cpu_seconds_total"] is None:
            continue
        result[key] = MetricSample(
            timestamp=data["timestamp"],
            cpu_seconds_total=data["cpu_seconds_total"],
            memory_rss_bytes=data["memory_rss_bytes"],
            throttle_count=data["throttle_count"],
        )
    return result


class CadvisorPoller:
    """Async Kubelet cAdvisor poller and rate transformation coordinator."""

    def __init__(
        self,
        node_name: str = "osramp-control-plane",
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        kubelet_url: Optional[str] = None,
        transport: Optional[httpx.AsyncBaseTransport] = None,
        stale_after: float = DEFAULT_STALE_AFTER,
        clock: Callable[[], float] = time.time,
    ):
        self.node_name = node_name
        self.poll_interval = poll_interval
        self.kubelet_url = kubelet_url or os.getenv(
            "CADVISOR_PROXY_URL",
            f"http://localhost:8001/api/v1/nodes/{node_name}/proxy/metrics/cadvisor",
        )
        self.transport = transport
        self.stale_after = stale_after
        self.clock = clock
        # Per container: the baseline sample and the last honest rate (None = no rate yet).
        self.containers: dict[str, tuple[MetricSample, Optional[float]]] = {}
        self.last_seen: dict[str, float] = {}
        # Per pod, keyed "namespace/pod".
        self.telemetry_cache: dict[str, AgentTelemetry] = {}
        self.subscribers: dict[str, list[asyncio.Queue]] = {}
        self.last_success: Optional[float] = None
        self.last_error: Optional[str] = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._scrape_fn: Optional[Callable[[], Any]] = None

    def set_scrape_override(self, fn: Callable[[], Any]) -> None:
        self._scrape_fn = fn

    def healthy(self) -> bool:
        """A scrape succeeded recently enough that the cache describes the present."""
        return self.last_success is not None and self.clock() - self.last_success <= self.stale_after

    async def scrape(self) -> str:
        if self._scrape_fn:
            res = self._scrape_fn()
            if asyncio.iscoroutine(res):
                return await res
            return str(res)

        async with httpx.AsyncClient(timeout=10.0, transport=self.transport) as client:
            resp = await client.get(self.kubelet_url)
            if resp.status_code >= 400:
                raise httpx.HTTPStatusError(
                    f"cAdvisor returned {resp.status_code}",
                    request=resp.request,
                    response=resp,
                )
            return resp.text

    async def poll_once(self) -> dict[str, AgentTelemetry]:
        try:
            samples = parse_cadvisor_metrics(await self.scrape(), now=self.clock())
        except Exception as exc:
            self.last_error = f"{type(exc).__name__}: {exc}"
            raise
        now = self.clock()
        pods: dict[tuple[str, str], list[tuple[MetricSample, Optional[float]]]] = {}

        for (ns, pod, container), curr in samples.items():
            key_str = f"{ns}/{pod}/{container}"
            self.last_seen[key_str] = now
            prev = self.containers.get(key_str)
            if prev is None:
                entry = (curr, None)
            elif curr.timestamp == prev[0].timestamp:
                # cAdvisor has not re-sampled (it refreshes every ~15 s): no new
                # information, so the previous rate stands and so does the baseline.
                entry = prev
            else:
                entry = (curr, compute_cpu_rate(curr, prev[0], curr.timestamp - prev[0].timestamp))
            self.containers[key_str] = entry
            pods.setdefault((ns, pod), []).append((curr, entry[1]))

        updates: dict[str, AgentTelemetry] = {}
        for (ns, pod), parts in pods.items():
            rates = [rate for _, rate in parts]
            millicores = None if any(r is None for r in rates) else sum(rates)
            if millicores is None:
                status = "PENDING"
            elif millicores == 0.0:
                millicores, status = 0.0, "FROZEN"
            else:
                status = "ACTIVE"
            telemetry = AgentTelemetry(
                pod_name=pod,
                namespace=ns,
                millicores=millicores,
                memory_rss_mb=sum(s.memory_rss_bytes for s, _ in parts) / (1024.0 * 1024.0),
                status=status,
                last_updated=datetime.fromtimestamp(max(s.timestamp for s, _ in parts), tz=timezone.utc).isoformat(),
            )
            self.telemetry_cache[f"{ns}/{pod}"] = telemetry
            updates[f"{ns}/{pod}"] = telemetry
            self._broadcast(pod, telemetry)

        for key_str, seen in list(self.last_seen.items()):
            if now - seen > CONTAINER_TTL:
                self.containers.pop(key_str, None)
                self.last_seen.pop(key_str, None)
        live_pods = {k.rsplit("/", 1)[0] for k in self.last_seen}
        for pod_key in list(self.telemetry_cache):
            if pod_key not in live_pods:
                del self.telemetry_cache[pod_key]

        self.last_success = now
        self.last_error = None
        return updates

    async def start(self) -> None:
        self._running = True
        self._task = asyncio.create_task(self._poll_loop())

    async def stop(self) -> None:
        self._running = False
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _poll_loop(self) -> None:
        backoff = 0.5
        max_backoff = 8.0

        while self._running:
            try:
                await self.poll_once()
                backoff = 0.5
            except Exception as exc:
                logger.warning("cAdvisor poller error (backing off %0.2fs): %s", backoff, exc)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2.0, max_backoff)
                continue

            await asyncio.sleep(self.poll_interval)

    def find_telemetry(self, pod_name: str) -> list[AgentTelemetry]:
        """Every monitored pod with this name, across namespaces."""
        return [t for t in self.telemetry_cache.values() if t.pod_name == pod_name]

    def get_all_telemetry(self) -> dict[str, dict[str, Any]]:
        return {k: v.to_dict() for k, v in self.telemetry_cache.items()}

    def subscribe(self, pod_name: str) -> Tuple[asyncio.Queue, Callable[[], None]]:
        queue: asyncio.Queue = asyncio.Queue(maxsize=20)
        self.subscribers.setdefault(pod_name, []).append(queue)

        for current in self.find_telemetry(pod_name):
            queue.put_nowait(current)

        def unsubscribe() -> None:
            subs = self.subscribers.get(pod_name, [])
            if queue in subs:
                subs.remove(queue)

        return queue, unsubscribe

    def subscriber_count(self, pod_name: str) -> int:
        return len(self.subscribers.get(pod_name, []))

    def _broadcast(self, pod_name: str, telemetry: AgentTelemetry) -> None:
        for q in list(self.subscribers.get(pod_name, [])):
            try:
                q.put_nowait(telemetry)
            except asyncio.QueueFull:
                pass


GLOBAL_CADVISOR_POLLER = CadvisorPoller()

router = APIRouter(tags=["telemetry"], dependencies=[Depends(authenticated_principal)])


def format_sse(item: AgentTelemetry) -> str:
    return f"data: {json.dumps(item.to_dict(), allow_nan=False)}\n\n"


def _require_fresh_telemetry() -> CadvisorPoller:
    poller = GLOBAL_CADVISOR_POLLER
    if not poller.healthy():
        detail = poller.last_error or "no successful cAdvisor scrape yet"
        raise APIError(503, "telemetry_unavailable", f"Agent telemetry is unavailable: {detail}")
    return poller


@router.get("/api/v1/telemetry/agents/{pod_name}")
@router.get("/api/telemetry/agents/{pod_name}")
async def get_agent_telemetry(
    pod_name: str, stream: bool = False, namespace: Optional[str] = None, request: Request = None
):
    poller = _require_fresh_telemetry()
    accept = request.headers.get("accept", "") if request else ""
    if stream or "text/event-stream" in accept:
        queue, unsubscribe = poller.subscribe(pod_name)

        async def sse_stream():
            try:
                while True:
                    item: AgentTelemetry = await queue.get()
                    if namespace is None or item.namespace == namespace:
                        yield format_sse(item)
            finally:
                unsubscribe()

        return StreamingResponse(
            sse_stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
                "Access-Control-Allow-Origin": "*",
            },
        )

    matches = [t for t in poller.find_telemetry(pod_name) if namespace is None or t.namespace == namespace]
    if not matches:
        raise APIError(404, "telemetry_not_found", "No telemetry for this agent pod")
    if len(matches) > 1:
        raise APIError(
            409, "telemetry_ambiguous_pod", "Pod name exists in several namespaces; pass ?namespace="
        )
    return JSONResponse(matches[0].to_dict())


@router.get("/api/v1/telemetry/agents")
@router.get("/api/telemetry/agents")
async def list_agent_telemetry():
    return JSONResponse(_require_fresh_telemetry().get_all_telemetry())


def install_cadvisor_telemetry_api(app: FastAPI) -> None:
    app.include_router(router)
