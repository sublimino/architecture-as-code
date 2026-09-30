"""cAdvisor poller, rate engine and telemetry API (SLDC-P4-1).

The rule every test here defends: the cockpit may only say FROZEN / 0.000 mCPU
when two distinct cAdvisor samples show no CPU work.  A first sample, a repeated
sample, an upstream failure or an unknown pod must never read as a freeze.
"""
from __future__ import annotations

import asyncio
import json
import math
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

import cadvisor_poller
from cadvisor_poller import (
    AgentTelemetry,
    CadvisorPoller,
    MetricSample,
    compute_cpu_rate,
    format_sse,
    parse_cadvisor_metrics,
)
from main import app
from conftest import EAPClient

EAP_AUTHENTICATED = True

VECTORS = json.loads(
    (Path(__file__).resolve().parents[2] / "pkg/telemetry/testdata/rate_vectors.json").read_text()
)["vectors"]

NS = "fe-signalloom-agents"
POD = "kusari-agent-77d9c-abcde"
T0_MS = 1790755040000


def scrape(cpu: str = "12.345", ts_ms: int = T0_MS, *, pod: str = POD, ns: str = NS, container: str = "kusari-agent",
           rss: str = "104857600") -> str:
    labels = f'container="{container}",namespace="{ns}",pod="{pod}"'
    return (
        f"container_cpu_usage_seconds_total{{{labels}}} {cpu} {ts_ms}\n"
        f"container_memory_rss{{{labels}}} {rss} {ts_ms}\n"
    )


class Clock:
    def __init__(self, now: float = 1_790_755_040.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


async def poll(poller: CadvisorPoller, text: str) -> dict:
    poller.set_scrape_override(lambda: text)
    return await poller.poll_once()


def pod_telemetry(poller: CadvisorPoller, pod: str = POD, ns: str = NS) -> AgentTelemetry:
    (match,) = [t for t in poller.find_telemetry(pod) if t.namespace == ns]
    return match


# --------------------------------------------------------------------------- rate engine


@pytest.mark.parametrize("v", VECTORS, ids=[v["name"] for v in VECTORS])
def test_rate_vectors_shared_with_go(v):
    prev = MetricSample(timestamp=0.0, cpu_seconds_total=float(v["prev"]), memory_rss_bytes=0)
    curr = MetricSample(timestamp=0.0, cpu_seconds_total=float(v["curr"]), memory_rss_bytes=0)
    got = compute_cpu_rate(curr, prev, float(v["dt"]))
    if v["want"] is None:
        assert got is None
    elif v["want"] == 0.0:
        assert got == 0.0 and math.copysign(1.0, got) == 1.0, f"want +0.000, got {got!r}"
    else:
        assert got == pytest.approx(v["want"], abs=1e-9)


# --------------------------------------------------------------------------- parser


def test_parse_keeps_agent_containers_and_drops_pause_and_foreign():
    text = (
        scrape()
        + f'container_cpu_usage_seconds_total{{container="POD",namespace="{NS}",pod="{POD}"}} 0.001 {T0_MS}\n'
        + f'container_cpu_usage_seconds_total{{container="",namespace="{NS}",pod="{POD}"}} 9 {T0_MS}\n'
        + f'container_cpu_usage_seconds_total{{container="coredns",namespace="kube-system",pod="coredns-1"}} 9 {T0_MS}\n'
    )
    samples = parse_cadvisor_metrics(text)
    assert list(samples) == [(NS, POD, "kusari-agent")]
    s = samples[(NS, POD, "kusari-agent")]
    assert (s.cpu_seconds_total, s.memory_rss_bytes, s.timestamp) == (12.345, 104857600, T0_MS / 1000)


def test_parse_drops_series_without_a_cpu_counter():
    labels = f'container="kusari-agent",namespace="{NS}",pod="{POD}"'
    assert parse_cadvisor_metrics(f"container_memory_rss{{{labels}}} 1048576 {T0_MS}\n") == {}


@pytest.mark.parametrize("bad", ["NaN", "+Inf", "-Inf", "-1"])
def test_parse_drops_non_finite_or_negative_cpu(bad):
    assert parse_cadvisor_metrics(scrape(cpu=bad)) == {}


@pytest.mark.parametrize("body", ["", "<html><body>Unauthorized</body></html>", "not prometheus at all\n"])
def test_parse_rejects_a_body_with_no_metric_lines(body):
    with pytest.raises(ValueError, match="no Prometheus samples"):
        parse_cadvisor_metrics(body)


def test_parse_accepts_a_scrape_with_no_agent_containers():
    text = f'container_cpu_usage_seconds_total{{container="coredns",namespace="kube-system",pod="c"}} 9 {T0_MS}\n'
    assert parse_cadvisor_metrics(text) == {}


# --------------------------------------------------------------------------- poller state machine


@pytest.mark.anyio
async def test_first_sample_is_pending_not_frozen():
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape())
    t = pod_telemetry(poller)
    assert (t.millicores, t.status) == (None, "PENDING")


@pytest.mark.anyio
async def test_second_distinct_sample_yields_active_rate():
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape("12.345", T0_MS))
    await poll(poller, scrape("12.545", T0_MS + 2000))
    t = pod_telemetry(poller)
    assert t.status == "ACTIVE"
    assert t.millicores == pytest.approx(100.0)


@pytest.mark.anyio
async def test_zero_delta_between_distinct_samples_is_exact_frozen_zero():
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape("13.820", T0_MS))
    await poll(poller, scrape("13.820", T0_MS + 15000))
    t = pod_telemetry(poller)
    assert t.status == "FROZEN"
    assert t.millicores == 0.0 and math.copysign(1.0, t.millicores) == 1.0
    assert json.loads(format_sse(t)[len("data: "):])["millicores"] == 0.0


@pytest.mark.anyio
async def test_unrefreshed_cadvisor_sample_keeps_the_previous_rate():
    # cAdvisor re-samples every ~15 s; a 2 s poll mostly sees the same sample.
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape("12.345", T0_MS))
    await poll(poller, scrape("12.545", T0_MS + 2000))
    await poll(poller, scrape("12.545", T0_MS + 2000))
    t = pod_telemetry(poller)
    assert (t.status, t.millicores) == ("ACTIVE", pytest.approx(100.0))
    await poll(poller, scrape("12.745", T0_MS + 4000))
    assert pod_telemetry(poller).millicores == pytest.approx(100.0)


@pytest.mark.anyio
async def test_timestamp_regression_rebaselines_as_pending():
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape("12.345", T0_MS))
    await poll(poller, scrape("12.545", T0_MS + 2000))
    await poll(poller, scrape("12.600", T0_MS - 5000))
    assert pod_telemetry(poller).status == "PENDING"


@pytest.mark.anyio
async def test_pod_rate_is_the_sum_of_its_containers():
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape("10", T0_MS) + scrape("5", T0_MS, container="envoy", rss="1048576"))
    await poll(poller, scrape("10.2", T0_MS + 2000) + scrape("5", T0_MS + 2000, container="envoy", rss="1048576"))
    t = pod_telemetry(poller)
    assert t.millicores == pytest.approx(100.0)
    assert t.memory_rss_mb == pytest.approx(101.0)


@pytest.mark.anyio
async def test_pod_is_pending_while_any_container_is_pending():
    poller = CadvisorPoller(clock=Clock())
    await poll(poller, scrape("10", T0_MS))
    await poll(poller, scrape("10.2", T0_MS + 2000) + scrape("5", T0_MS + 2000, container="envoy"))
    assert pod_telemetry(poller).status == "PENDING"


@pytest.mark.anyio
async def test_same_pod_name_in_two_namespaces_is_kept_apart():
    poller = CadvisorPoller(clock=Clock())
    text = scrape("1", T0_MS, ns="tenant-a", pod="kusari-agent-0") + scrape("9", T0_MS, ns="tenant-b", pod="kusari-agent-0")
    await poll(poller, text)
    text2 = scrape("1", T0_MS + 2000, ns="tenant-a", pod="kusari-agent-0") + scrape("9.2", T0_MS + 2000, ns="tenant-b", pod="kusari-agent-0")
    await poll(poller, text2)
    assert pod_telemetry(poller, "kusari-agent-0", "tenant-a").status == "FROZEN"
    assert pod_telemetry(poller, "kusari-agent-0", "tenant-b").millicores == pytest.approx(100.0)


@pytest.mark.anyio
async def test_vanished_pod_is_evicted_after_ttl():
    clock = Clock()
    poller = CadvisorPoller(clock=clock)
    await poll(poller, scrape())
    clock.now += 61
    await poll(poller, scrape(pod="other-pod"))
    assert poller.find_telemetry(POD) == []


# --------------------------------------------------------------------------- upstream failures


def kubelet(handler) -> CadvisorPoller:
    return CadvisorPoller(kubelet_url="http://kubelet.test/metrics/cadvisor", transport=httpx.MockTransport(handler), clock=Clock())


@pytest.mark.anyio
@pytest.mark.parametrize("status", [401, 403, 500, 504])
async def test_kubelet_error_status_fails_the_poll_and_marks_unhealthy(status):
    poller = kubelet(lambda req: httpx.Response(status, text="denied"))
    with pytest.raises(httpx.HTTPStatusError):
        await poller.poll_once()
    assert not poller.healthy()
    assert str(status) in poller.last_error


@pytest.mark.anyio
async def test_kubelet_timeout_fails_the_poll_and_marks_unhealthy():
    def timeout(req):
        raise httpx.ReadTimeout("kubelet slow", request=req)

    poller = kubelet(timeout)
    with pytest.raises(httpx.ReadTimeout):
        await poller.poll_once()
    assert not poller.healthy()


@pytest.mark.anyio
async def test_malformed_scrape_fails_the_poll_and_marks_unhealthy():
    poller = kubelet(lambda req: httpx.Response(200, text="<html>login</html>"))
    with pytest.raises(ValueError):
        await poller.poll_once()
    assert not poller.healthy()


@pytest.mark.anyio
async def test_successful_scrape_is_healthy_until_it_goes_stale():
    clock = Clock()
    poller = CadvisorPoller(clock=clock, stale_after=15.0)
    await poll(poller, scrape())
    assert poller.healthy()
    clock.now += 15.1
    assert not poller.healthy()


@pytest.mark.anyio
async def test_poll_loop_backs_off_exponentially_to_cap_then_resets(monkeypatch):
    poller = CadvisorPoller(poll_interval=2.0, clock=Clock())
    outcomes = iter([False] * 6 + [True, False])
    delays: list[float] = []

    def scrape_once():
        if next(outcomes):
            return scrape()
        raise httpx.ConnectError("refused")

    async def fake_sleep(d):
        delays.append(d)
        if len(delays) == 8:
            poller._running = False

    poller.set_scrape_override(scrape_once)
    monkeypatch.setattr(cadvisor_poller.asyncio, "sleep", fake_sleep)
    poller._running = True
    await poller._poll_loop()
    assert delays == [0.5, 1.0, 2.0, 4.0, 8.0, 8.0, 2.0, 0.5]


# --------------------------------------------------------------------------- HTTP API


@pytest.fixture
def poller(monkeypatch) -> CadvisorPoller:
    p = CadvisorPoller(clock=Clock())
    monkeypatch.setattr(cadvisor_poller, "GLOBAL_CADVISOR_POLLER", p)
    return p


@pytest.fixture
def client() -> EAPClient:
    return EAPClient(app)


def error_code(resp) -> str:
    return resp.json()["error"]["code"]


@pytest.mark.parametrize(
    "path",
    ["/api/telemetry/agents", "/api/v1/telemetry/agents", f"/api/telemetry/agents/{POD}", f"/api/v1/telemetry/agents/{POD}?stream=true"],
)
def test_routes_reject_anonymous_callers(path, poller):
    resp = TestClient(app).get(path)
    assert resp.status_code == 401
    assert error_code(resp) == "authentication_required"


@pytest.mark.parametrize(
    "path", ["/api/telemetry/agents", f"/api/telemetry/agents/{POD}", f"/api/telemetry/agents/{POD}?stream=true"]
)
def test_routes_are_503_when_the_poller_never_scraped(path, poller, client):
    resp = client.get(path)
    assert resp.status_code == 503
    assert error_code(resp) == "telemetry_unavailable"


@pytest.mark.anyio
async def test_routes_are_503_when_the_last_scrape_is_stale(poller, client):
    await poll(poller, scrape())
    poller.clock.now += 3600
    resp = client.get(f"/api/telemetry/agents/{POD}")
    assert resp.status_code == 503
    assert error_code(resp) == "telemetry_unavailable"


@pytest.mark.anyio
async def test_unknown_pod_is_404_not_a_fabricated_freeze(poller, client):
    await poll(poller, scrape())
    for pod in ("no-such-pod", "kusari"):
        resp = client.get(f"/api/telemetry/agents/{pod}")
        assert resp.status_code == 404
        assert error_code(resp) == "telemetry_not_found"
        assert "FROZEN" not in resp.text


@pytest.mark.anyio
async def test_known_pod_returns_its_telemetry(poller, client):
    await poll(poller, scrape("12.345", T0_MS))
    await poll(poller, scrape("12.545", T0_MS + 2000))
    resp = client.get(f"/api/v1/telemetry/agents/{POD}")
    assert resp.status_code == 200
    body = resp.json()
    assert body == {
        "pod_name": POD,
        "namespace": NS,
        "millicores": pytest.approx(100.0),
        "memory_rss_mb": 100.0,
        "status": "ACTIVE",
        "last_updated": "2026-09-30T07:57:22+00:00",
    }


@pytest.mark.anyio
async def test_pending_pod_reports_null_millicores(poller, client):
    await poll(poller, scrape())
    body = client.get(f"/api/telemetry/agents/{POD}").json()
    assert (body["millicores"], body["status"]) == (None, "PENDING")


@pytest.mark.anyio
async def test_ambiguous_pod_name_is_409_and_namespace_disambiguates(poller, client):
    await poll(poller, scrape(ns="tenant-a", pod="kusari-agent-0") + scrape(ns="tenant-b", pod="kusari-agent-0"))
    resp = client.get("/api/telemetry/agents/kusari-agent-0")
    assert resp.status_code == 409
    assert error_code(resp) == "telemetry_ambiguous_pod"
    resp = client.get("/api/telemetry/agents/kusari-agent-0", params={"namespace": "tenant-b"})
    assert resp.status_code == 200
    assert resp.json()["namespace"] == "tenant-b"


@pytest.mark.anyio
async def test_list_is_keyed_by_namespace_and_pod(poller, client):
    await poll(poller, scrape(ns="tenant-a", pod="kusari-agent-0") + scrape(ns="tenant-b", pod="kusari-agent-0"))
    body = client.get("/api/telemetry/agents").json()
    assert sorted(body) == ["tenant-a/kusari-agent-0", "tenant-b/kusari-agent-0"]


@pytest.mark.parametrize("method", ["POST", "PUT", "DELETE"])
def test_write_methods_are_405(method, poller, client):
    resp = client.request(method, f"/api/telemetry/agents/{POD}")
    assert resp.status_code == 405
    assert error_code(resp) == "method_not_allowed"


def test_sse_frame_is_strict_json():
    t = AgentTelemetry(pod_name="p'o\"d", namespace="n", millicores=None, memory_rss_mb=1.0, status="PENDING", last_updated="x")
    frame = format_sse(t)
    assert frame.startswith("data: ") and frame.endswith("\n\n")
    assert json.loads(frame[len("data: "):]) == {**t.to_dict(), "millicores": None}


@pytest.mark.anyio
async def test_sse_stream_sends_current_state_and_unsubscribes_on_disconnect(poller):
    await poll(poller, scrape())
    resp = await cadvisor_poller.get_agent_telemetry(POD, stream=True, namespace=None, request=None)
    assert resp.media_type == "text/event-stream"
    assert resp.headers["cache-control"] == "no-cache"
    first = await asyncio.wait_for(resp.body_iterator.__anext__(), timeout=1)
    assert json.loads(first[len("data: "):])["pod_name"] == POD
    assert poller.subscriber_count(POD) == 1
    await resp.body_iterator.aclose()
    assert poller.subscriber_count(POD) == 0
