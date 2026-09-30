"""Unit tests for cAdvisor proxy poller and rate transformation engine (SLDC-P4-1)."""
import asyncio
import math
import time
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
import httpx

from cadvisor_poller import (
    AgentTelemetry,
    CadvisorPoller,
    MetricSample,
    compute_cpu_rate,
    parse_cadvisor_metrics,
    router,
)
from main import app

SAMPLE_PROMETHEUS_METRICS = """# HELP container_cpu_usage_seconds_total Cumulative cpu time consumed in seconds.
# TYPE container_cpu_usage_seconds_total counter
container_cpu_usage_seconds_total{container="kusari-agent",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 12.345 1790755040000
container_cpu_usage_seconds_total{container="POD",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 0.001 1790755040000
container_cpu_usage_seconds_total{container="",namespace="kube-system",pod="kube-proxy-abcde"} 45.678 1790755040000
# HELP container_memory_rss Size of RSS in bytes.
# TYPE container_memory_rss gauge
container_memory_rss{container="kusari-agent",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 104857600 1790755040000
# HELP container_cpu_cfs_throttled_periods_total Number of throttled period intervals.
# TYPE container_cpu_cfs_throttled_periods_total counter
container_cpu_cfs_throttled_periods_total{container="kusari-agent",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 3 1790755040000
"""


def test_parse_metrics():
    """Verify Prometheus text exposition format is deserialized into MetricSample objects."""
    samples = parse_cadvisor_metrics(SAMPLE_PROMETHEUS_METRICS)

    target_key = ("fe-signalloom-agents", "kusari-agent-77d9c-abcde", "kusari-agent")
    assert target_key in samples, f"Target key {target_key} not found in parsed samples"

    sample = samples[target_key]
    assert math.isclose(sample.cpu_seconds_total, 12.345, rel_tol=1e-5)
    assert sample.memory_rss_bytes == 104857600
    assert sample.throttle_count == 3

    # Ensure non-agent and POD containers are discarded immediately
    for ns, pod, cont in samples.keys():
        assert cont != "POD"
        assert cont != ""
        assert ns == "fe-signalloom-agents" or cont == "kusari-agent"


def test_cpu_rate_derivative():
    """Verify rate derivative calculation (delta_usage / delta_t * 1000) matches expected mCPU."""
    prev = MetricSample(timestamp=1000.0, cpu_seconds_total=10.0, memory_rss_bytes=64 * 1024 * 1024)
    curr = MetricSample(timestamp=1002.0, cpu_seconds_total=10.2, memory_rss_bytes=64 * 1024 * 1024)

    delta_t = 2.0
    rate = compute_cpu_rate(curr, prev, delta_t)
    expected_rate = 100.0  # (0.2 / 2.0) * 1000 = 100.0 mCPU

    assert math.isclose(rate, expected_rate, abs_tol=0.001), f"Expected {expected_rate} mCPU, got {rate}"


def test_frozen_pod_zero_rate():
    """Verify that when cumulative counter does not increment (delta < 0.0001), rate is exactly 0.000 mCPU."""
    prev = MetricSample(timestamp=1000.0, cpu_seconds_total=42.123456, memory_rss_bytes=128 * 1024 * 1024)
    # Zero delta
    curr_zero = MetricSample(timestamp=1002.0, cpu_seconds_total=42.123456, memory_rss_bytes=128 * 1024 * 1024)
    rate_zero = compute_cpu_rate(curr_zero, prev, 2.0)
    assert rate_zero == 0.0, f"Expected 0.000 mCPU for exact zero delta, got {rate_zero}"

    # Tiny delta below freeze threshold (0.00005 < 0.0001)
    curr_tiny = MetricSample(timestamp=1002.0, cpu_seconds_total=42.123500, memory_rss_bytes=128 * 1024 * 1024)
    rate_tiny = compute_cpu_rate(curr_tiny, prev, 2.0)
    assert rate_tiny == 0.0, f"Expected 0.000 mCPU for sub-epsilon delta, got {rate_tiny}"


def test_container_restart_counter_rollover():
    """Verify that when a container restarts and counter resets to lower value, rate stays non-negative."""
    prev = MetricSample(timestamp=1000.0, cpu_seconds_total=150.0, memory_rss_bytes=64 * 1024 * 1024)
    curr = MetricSample(timestamp=1002.0, cpu_seconds_total=0.5, memory_rss_bytes=64 * 1024 * 1024)

    rate = compute_cpu_rate(curr, prev, 2.0)
    expected_rate = (0.5 / 2.0) * 1000.0  # 250.0 mCPU
    assert math.isclose(rate, expected_rate, abs_tol=0.001)
    assert rate >= 0.0


def test_zero_or_negative_delta_time():
    """Verify that non-positive delta_sec returns 0.0 without division by zero or NaN."""
    prev = MetricSample(timestamp=1000.0, cpu_seconds_total=10.0, memory_rss_bytes=0)
    curr = MetricSample(timestamp=1000.0, cpu_seconds_total=12.0, memory_rss_bytes=0)

    assert compute_cpu_rate(curr, prev, 0.0) == 0.0
    assert compute_cpu_rate(curr, prev, -1.0) == 0.0


@pytest.mark.anyio
async def test_poller_http_error_backoff():
    """Verify simulated HTTP 500/504 responses trigger exponential backoff without crashing poller worker."""
    poller = CadvisorPoller(poll_interval=0.05)

    error_count = 0

    async def failing_scrape():
        nonlocal error_count
        error_count += 1
        request = httpx.Request("GET", "http://test")
        response = httpx.Response(500 if error_count % 2 == 1 else 504, request=request)
        raise httpx.HTTPStatusError("Kubelet proxy error", request=request, response=response)

    poller.set_scrape_override(failing_scrape)

    await poller.start()
    await asyncio.sleep(0.3)
    await poller.stop()

    assert error_count >= 1, "Poller should have attempted scrape and handled HTTP error"
    assert not poller._running


@pytest.mark.anyio
async def test_poller_collection_lifecycle_and_sse():
    """Verify end-to-end poller collection and SSE subscriber broadcast."""
    poller = CadvisorPoller(poll_interval=0.1)

    # Initial scrape
    poller.set_scrape_override(lambda: SAMPLE_PROMETHEUS_METRICS)
    updates = await poller.poll_once()

    assert "kusari-agent-77d9c-abcde" in updates
    t1 = updates["kusari-agent-77d9c-abcde"]
    assert t1.millicores == 0.0
    assert math.isclose(t1.memory_rss_mb, 100.0, abs_tol=0.1)

    # Subscribe to SSE
    queue, unsubscribe = poller.subscribe("kusari-agent-77d9c-abcde")
    assert poller.subscriber_count("kusari-agent-77d9c-abcde") == 1

    # Second scrape with CPU increase
    metrics2 = SAMPLE_PROMETHEUS_METRICS.replace("12.345", "12.545").replace("1790755040000", "1790755042000")
    poller.set_scrape_override(lambda: metrics2)
    updates2 = await poller.poll_once()

    t2 = updates2["kusari-agent-77d9c-abcde"]
    assert math.isclose(t2.millicores, 100.0, abs_tol=0.5)
    assert t2.status == "ACTIVE"

    # Verify queue received item
    received = await queue.get()
    assert received.pod_name == "kusari-agent-77d9c-abcde"

    # Unsubscribe
    unsubscribe()
    assert poller.subscriber_count("kusari-agent-77d9c-abcde") == 0


def test_telemetry_rest_api():
    """Verify REST API endpoint /api/v1/telemetry/agents/{pod} returns calculated mCPU."""
    client = TestClient(app)

    resp = client.get("/api/v1/telemetry/agents/kusari")
    assert resp.status_code == 200
    data = resp.json()
    assert "millicores" in data
    assert "memory_rss_mb" in data
    assert "status" in data
