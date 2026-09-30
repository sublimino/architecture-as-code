"""cAdvisor proxy poller and rate transformation engine (SLDC-P4-1).

Scrapes Kubelet cAdvisor proxy metrics every 2 seconds, calculates real-time
CPU consumption in millicores using rate differentials, and enforces the freeze
flatline invariant (delta CPU < 0.0001s outputs exact 0.000 mCPU).
"""
from __future__ import annotations

import asyncio
import logging
import math
import os
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Dict, Optional, Tuple

import httpx
from fastapi import APIRouter, FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

logger = logging.getLogger("signalloom.cadvisor")

FREEZE_EPSILON = 0.0001  # 0.1 ms threshold for freeze flatline invariant
DEFAULT_POLL_INTERVAL = 2.0


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
    millicores: float
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


def compute_cpu_rate(curr: MetricSample, prev: MetricSample, delta_sec: float) -> float:
    """Calculate CPU consumption in millicores with rollover protection and freeze invariant."""
    if delta_sec <= 0.0:
        return 0.0

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


def parse_cadvisor_metrics(prom_text: str) -> dict[Tuple[str, str, str], MetricSample]:
    """Parse raw Prometheus cAdvisor exposition text and filter agent containers."""
    samples: dict[Tuple[str, str, str], dict[str, Any]] = {}
    now_ts = time.time()

    for line in prom_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        match = _METRIC_LINE_RE.match(line)
        if not match:
            continue

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
                "cpu_seconds_total": 0.0,
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

    result: dict[Tuple[str, str, str], MetricSample] = {}
    for key, data in samples.items():
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
    ):
        self.node_name = node_name
        self.poll_interval = poll_interval
        self.kubelet_url = kubelet_url or os.getenv(
            "CADVISOR_PROXY_URL",
            f"http://localhost:8001/api/v1/nodes/{node_name}/proxy/metrics/cadvisor",
        )
        self.sample_cache: dict[str, MetricSample] = {}
        self.last_seen: dict[str, float] = {}
        self.telemetry_cache: dict[str, AgentTelemetry] = {}
        self.subscribers: dict[str, list[asyncio.Queue]] = {}
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._scrape_fn: Optional[Callable[[], Any]] = None

    def set_scrape_override(self, fn: Callable[[], Any]) -> None:
        self._scrape_fn = fn

    async def scrape(self) -> str:
        if self._scrape_fn:
            res = self._scrape_fn()
            if asyncio.iscoroutine(res):
                return await res
            return str(res)

        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(self.kubelet_url)
            if resp.status_code >= 400:
                raise httpx.HTTPStatusError(
                    f"cAdvisor returned {resp.status_code}",
                    request=resp.request,
                    response=resp,
                )
            return resp.text

    async def poll_once(self) -> dict[str, AgentTelemetry]:
        raw_text = await self.scrape()
        samples = parse_cadvisor_metrics(raw_text)
        now = time.time()
        updates: dict[str, AgentTelemetry] = {}

        for (ns, pod, container), curr in samples.items():
            key_str = f"{ns}/{pod}/{container}"
            self.last_seen[key_str] = now

            prev = self.sample_cache.get(key_str)
            if prev is not None:
                delta_sec = curr.timestamp - prev.timestamp
                if delta_sec <= 0.0:
                    delta_sec = self.poll_interval
                millicores = compute_cpu_rate(curr, prev, delta_sec)
            else:
                millicores = 0.0

            self.sample_cache[key_str] = curr

            mem_mb = curr.memory_rss_bytes / (1024.0 * 1024.0)
            status = "FROZEN" if millicores == 0.0 else "ACTIVE"

            last_iso = datetime.fromtimestamp(curr.timestamp, tz=timezone.utc).isoformat()
            telemetry = AgentTelemetry(
                pod_name=pod,
                namespace=ns,
                millicores=millicores,
                memory_rss_mb=mem_mb,
                status=status,
                last_updated=last_iso,
            )

            self.telemetry_cache[pod] = telemetry
            self.telemetry_cache[key_str] = telemetry
            updates[pod] = telemetry
            self._broadcast(pod, telemetry)

        # Cleanup stale containers > 60s
        for key_str, seen in list(self.last_seen.items()):
            if now - seen > 60.0:
                self.sample_cache.pop(key_str, None)
                self.last_seen.pop(key_str, None)

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

    def get_telemetry(self, pod_name: str) -> Optional[AgentTelemetry]:
        return self.telemetry_cache.get(pod_name)

    def get_all_telemetry(self) -> dict[str, dict[str, Any]]:
        # Return unique pods
        seen = {}
        for k, v in self.telemetry_cache.items():
            if "/" not in k:
                seen[k] = v.to_dict()
        return seen

    def subscribe(self, pod_name: str) -> Tuple[asyncio.Queue, Callable[[], None]]:
        queue: asyncio.Queue = asyncio.Queue(maxsize=20)
        self.subscribers.setdefault(pod_name, []).append(queue)

        # Send initial sample if present
        if pod_name in self.telemetry_cache:
            queue.put_nowait(self.telemetry_cache[pod_name])

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

router = APIRouter(tags=["telemetry"])


@router.get("/api/v1/telemetry/agents/{pod_name}")
@router.get("/api/telemetry/agents/{pod_name}")
async def get_agent_telemetry(pod_name: str, stream: bool = False, request: Request = None):
    # Check SSE
    accept = request.headers.get("accept", "") if request else ""
    if stream or "text/event-stream" in accept:
        queue, unsubscribe = GLOBAL_CADVISOR_POLLER.subscribe(pod_name)

        async def sse_stream():
            try:
                while True:
                    item: AgentTelemetry = await queue.get()
                    data_json = str(item.to_dict()).replace("'", '"')
                    yield f"data: {data_json}\n\n"
            except asyncio.CancelledError:
                pass
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

    # Regular JSON lookup
    # Handle 'all' or specific pod
    if pod_name in ("all", "*"):
        return JSONResponse(GLOBAL_CADVISOR_POLLER.get_all_telemetry())

    # Fallback lookup: if pod is 'kusari', match any kusari agent
    tel = GLOBAL_CADVISOR_POLLER.get_telemetry(pod_name)
    if not tel and pod_name == "kusari":
        for k, v in GLOBAL_CADVISOR_POLLER.telemetry_cache.items():
            if "kusari" in k:
                tel = v
                break

    if not tel:
        # Default placeholder if pod not scraped yet
        return JSONResponse(
            {
                "pod_name": pod_name,
                "namespace": "fe-signalloom-agents",
                "millicores": 0.0,
                "memory_rss_mb": 0.0,
                "status": "FROZEN",
                "last_updated": datetime.now(timezone.utc).isoformat(),
            }
        )

    return JSONResponse(tel.to_dict())


@router.get("/api/v1/telemetry/agents")
@router.get("/api/telemetry/agents")
async def list_agent_telemetry():
    return JSONResponse(GLOBAL_CADVISOR_POLLER.get_all_telemetry())


def install_cadvisor_telemetry_api(app: FastAPI) -> None:
    app.include_router(router)
