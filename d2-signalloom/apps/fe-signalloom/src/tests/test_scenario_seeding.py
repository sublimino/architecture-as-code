# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_scenario_seeding.py
# Unit and contract tests for Signal Loom EAP Scenario Seeding Engine (SLES)
# ==============================================================================
from datetime import datetime, timezone
import pytest
from fastapi.testclient import TestClient

from scenario_seeding import (
    ScenarioType,
    SyntheticAuditEvent,
    ScenarioManager,
    GLOBAL_SCENARIO_MANAGER,
    generate_baseline_agent_events,
    generate_prompt_injection_intercept_events,
    generate_lateral_traversal_blocked_events,
    generate_compliance_proof_events,
)
from main import app
import eap_tenancy
from conftest import EAP_TENANT_A, EAPClient, eap_bearer

# EAPR-P2-1: the scenarios router is mounted behind authenticated_principal;
# every request here carries a real tenant-a token (see tests/conftest.py).
EAP_AUTHENTICATED = True
client = EAPClient(app)


def test_baseline_agent_events_generation():
    """Verify baseline agent workflow generates expected control/data/policy events."""
    events = generate_baseline_agent_events("kurasi", "6f82ad81")
    assert len(events) == 3

    # Check planes
    planes = [e.plane for e in events]
    assert "control" in planes
    assert "data" in planes
    assert "policy" in planes

    # Check tenant isolation attributes
    for event in events:
        assert event.customer_hash == "6f82ad81"
        assert event.company_name == "kurasi"
        assert event.namespace == "eap-6f82ad81"
        assert event.verdict == "ALLOW"
        assert event.risk_score <= 0.15


def test_prompt_injection_intercept_events():
    """Verify prompt injection scenario generates detection, intercept, and quarantine events."""
    events = generate_prompt_injection_intercept_events("kurasi", "6f82ad81")
    assert len(events) == 3

    verdicts = [e.verdict for e in events]
    assert "ALLOW" in verdicts
    assert "INTERCEPT" in verdicts
    assert "BLOCK" in verdicts

    # Intercept event must reflect high risk score and guardrail detail
    intercept_event = next(e for e in events if e.verdict == "INTERCEPT")
    assert intercept_event.risk_score >= 0.90
    assert intercept_event.details["guardrail_rule_id"] == "SEC-PROMPT-0412"
    assert "override" in intercept_event.details["violation"].lower()


def test_lateral_traversal_blocked_events():
    """Verify lateral movement attempt generates network policy block event."""
    events = generate_lateral_traversal_blocked_events("kurasi", "6f82ad81")
    assert len(events) == 2

    block_event = next(e for e in events if e.verdict == "BLOCK")
    assert block_event.plane == "policy"
    assert block_event.agent_id == "kubesec-afm-firewall"
    assert block_event.risk_score >= 0.90
    assert block_event.details["target_namespace"] == "production-core"
    assert block_event.details["remediation"] == "Packet dropped at CNI ingress boundary"


def test_compliance_proof_events():
    """Verify compliance attestation proof generates transit-signed event."""
    events = generate_compliance_proof_events("kurasi", "6f82ad81")
    assert len(events) == 1

    proof = events[0]
    assert proof.plane == "control"
    assert proof.verdict == "ALLOW"
    assert proof.risk_score == 0.0
    assert proof.details["key_mount"] == "transit/keys/eap-6f82ad81"
    assert "spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app" in proof.details["spiffe_id"]


def test_scenario_manager_execution_and_storage():
    """Verify ScenarioManager tracks execution history and customer event indexing."""
    mgr = ScenarioManager()

    res = mgr.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", "6f82ad81")
    assert res.customer_hash == "6f82ad81"
    assert res.events_generated_count == 3
    assert res.duration_ms >= 0.0

    # Retrieve indexed events
    events = mgr.get_events_for_customer("6f82ad81")
    assert len(events) == 3

    # Add another scenario
    res2 = mgr.execute_scenario(ScenarioType.PROMPT_INJECTION_INTERCEPT, "kurasi", "6f82ad81")
    assert res2.events_generated_count == 3

    events_all = mgr.get_events_for_customer("6f82ad81")
    assert len(events_all) == 6

    history = mgr.get_history()
    assert len(history) == 2


def test_api_execute_scenario_endpoint():
    """Verify POST /api/v1/eap/scenarios/execute returns 201 Created and structured result."""
    payload = {
        "scenario_type": "lateral_traversal_blocked",
        "company_name": "kurasi",
        "customer_hash": "6f82ad81",
    }
    resp = client.post("/api/v1/eap/scenarios/execute", json=payload)
    assert resp.status_code == 201
    data = resp.json()

    assert data["customer_hash"] == "6f82ad81"
    assert data["scenario_type"] == "lateral_traversal_blocked"
    assert data["events_generated_count"] == 2
    assert len(data["events"]) == 2


def test_api_get_customer_events_endpoint():
    """Verify GET /api/v1/eap/scenarios/events/{customer_hash} returns generated events."""
    # Execute a scenario first
    client.post("/api/v1/eap/scenarios/execute", json={
        "scenario_type": "compliance_proof",
        "company_name": "kurasi",
        "customer_hash": "6f82ad81",
    })

    resp = client.get("/api/v1/eap/scenarios/events/6f82ad81")
    assert resp.status_code == 200
    events = resp.json()
    assert isinstance(events, list)
    assert len(events) >= 1

    # Check for compliance proof event
    assert any(e["agent_id"] == "signalloom-attestor" for e in events)


def test_api_get_history_endpoint():
    """Verify GET /api/v1/eap/scenarios/history returns execution log."""
    # Seed our own run: this test used to rely on an earlier test having
    # executed one, so `-k test_api_get_history_endpoint` alone failed 0 >= 1.
    seeded = client.post("/api/v1/eap/scenarios/execute", json={
        "scenario_type": "baseline_agent_flow",
        "company_name": "kurasi",
        "customer_hash": "6f82ad81",
    }).json()["execution_id"]

    resp = client.get("/api/v1/eap/scenarios/history")
    assert resp.status_code == 200
    history = resp.json()
    assert isinstance(history, list)
    assert seeded in {r["execution_id"] for r in history}


# ==============================================================================
# SLES-P4-2: multi-tenant concurrency and stress suite
#
# Everything below drives ScenarioManager from many threads at once and checks
# the four properties the EAP demo depends on: tenants never see each other's
# events, no execution is lost or half-written, the lock never deadlocks, and
# latency and memory stay flat under load. Benchmarks and the isolation contract
# are written up in docs/signalloom/sles-concurrency.md.
#
# The stress parameters are configurable, so the same harness serves as the
# stress script:
#   SLES_STRESS_TENANTS=20 SLES_STRESS_ITERATIONS=50 pytest -k stress
#   python tests/test_scenario_seeding.py --tenants 40 --iterations 200 --workers 16
# ==============================================================================
import gc
import json
import os
import resource
import statistics
import sys
import threading
import time
import tracemalloc
from concurrent.futures import ThreadPoolExecutor, as_completed, wait

from environment_routing import derive_customer_hash

EVALUATION_TENANTS = {
    "kurasi": "6f82ad81",
    "acme": "a1b2c3d4",
    "globex": "e5f6a7b8",
}
ALL_SCENARIOS = list(ScenarioType)
EVENTS_PER_SCENARIO = {
    ScenarioType.BASELINE_AGENT_FLOW: 3,
    ScenarioType.PROMPT_INJECTION_INTERCEPT: 3,
    ScenarioType.LATERAL_TRAVERSAL_BLOCKED: 2,
    ScenarioType.COMPLIANCE_PROOF: 1,
}
# Hang guard for every executor wait. Hitting it means a deadlock, not slowness:
# the heaviest workload here finishes in well under a second.
DEADLOCK_TIMEOUT_S = 30.0


def _percentile(samples, pct):
    ordered = sorted(samples)
    idx = min(len(ordered) - 1, max(0, round(pct / 100 * (len(ordered) - 1))))
    return ordered[idx]


@pytest.fixture
def preemptive_scheduler():
    """Force a GIL handoff roughly every microsecond instead of every 5ms.

    Without this, a thread usually finishes a whole execute_scenario call inside
    one time slice and the lock is never contended, so the concurrency tests
    would pass even against an unlocked manager.
    """
    previous = sys.getswitchinterval()
    sys.setswitchinterval(1e-6)
    try:
        yield
    finally:
        sys.setswitchinterval(previous)


def _run_tenant_sequence(mgr, barrier, company, customer_hash, iterations):
    """One worker: wait for the others, then execute scenarios back to back."""
    barrier.wait(timeout=DEADLOCK_TIMEOUT_S)
    ids, latencies_ms = [], []
    for i in range(iterations):
        scenario = ALL_SCENARIOS[i % len(ALL_SCENARIOS)]
        t0 = time.perf_counter()
        res = mgr.execute_scenario(scenario, company, customer_hash)
        latencies_ms.append((time.perf_counter() - t0) * 1000)
        ids.append(res.execution_id)
    return customer_hash, ids, latencies_ms


def _dispatch(mgr, assignments, iterations):
    """Run one worker per (company, hash) assignment, all released together."""
    barrier = threading.Barrier(len(assignments))
    with ThreadPoolExecutor(max_workers=len(assignments)) as pool:
        futures = [
            pool.submit(_run_tenant_sequence, mgr, barrier, company, h, iterations)
            for company, h in assignments
        ]
        done, pending = wait(futures, timeout=DEADLOCK_TIMEOUT_S)
        assert not pending, f"{len(pending)} workers still running after {DEADLOCK_TIMEOUT_S}s: deadlock"
        return [f.result() for f in futures]


def _assert_index_consistent(mgr):
    """Check the event index and history agree exactly, with every write whole.

    execute_scenario extends the tenant list and appends to history in one
    critical section. If that ever stopped being atomic, one of these breaks:
    an execution's events would be split up or interleaved with another's, an
    event would be missing or duplicated, or it would land under the wrong hash.
    """
    history = mgr.get_history()
    positions = {}
    for h in {r.customer_hash for r in history}:
        for pos, ev in enumerate(mgr.get_events_for_customer(h)):
            assert ev.event_id not in positions, f"duplicate event {ev.event_id}"
            positions[ev.event_id] = (h, pos)
    expected_total = 0
    for res in history:
        assert res.events_generated_count == len(res.events) == EVENTS_PER_SCENARIO[res.scenario_type]
        expected_total += res.events_generated_count
        slots = [positions[ev.event_id] for ev in res.events]
        assert {h for h, _ in slots} == {res.customer_hash}, "event indexed under a foreign tenant"
        first = slots[0][1]
        assert [p for _, p in slots] == list(range(first, first + len(slots))), (
            f"execution {res.execution_id} was not appended as one contiguous block"
        )
    assert len(positions) == expected_total, "event index and history disagree on event count"


def test_multitenant_scenario_concurrency_and_stress(preemptive_scheduler):
    """Three evaluation tenants x ten threads, all released at once.

    Each tenant gets 50 executions: 10 workers per tenant would be 30 threads,
    so the card's "ten concurrent workers" is read as ten per tenant pool,
    each worker running 5 scenarios.
    """
    mgr = ScenarioManager()
    workers_per_tenant, iterations = 10, 5
    assignments = [
        (company, h) for company, h in EVALUATION_TENANTS.items() for _ in range(workers_per_tenant)
    ]
    results = _dispatch(mgr, assignments, iterations)

    # Strict isolation: each tenant's query returns only its own events, and all of them.
    for company, h in EVALUATION_TENANTS.items():
        events = mgr.get_events_for_customer(h)
        foreign = [e for e in events if e.customer_hash != h or e.namespace != f"eap-{h}"]
        assert foreign == [], f"{company} query leaked {len(foreign)} events from other tenants"
        assert {e.company_name for e in events} == {company}
        runs = [r for r in mgr.get_history() if r.customer_hash == h]
        assert len(runs) == workers_per_tenant * iterations == 50
        assert len(events) == sum(r.events_generated_count for r in runs)

    # No lost or torn writes anywhere.
    history = mgr.get_history()
    assert len(history) == len(assignments) * iterations == 150
    _assert_index_consistent(mgr)

    # Ordering: a worker runs sequentially, so history must preserve each
    # worker's own order even though workers interleave with each other.
    history_pos = {r.execution_id: i for i, r in enumerate(history)}
    for _, ids, _ in results:
        order = [history_pos[i] for i in ids]
        assert order == sorted(order), "history reordered a worker's executions"

    # Latency: every one of the 150 contended executions under 50ms.
    latencies = [ms for _, _, lat in results for ms in lat]
    assert max(latencies) < 50.0, f"slowest execution {max(latencies):.2f}ms"


def test_concurrent_readers_and_writers_do_not_deadlock(preemptive_scheduler):
    """Readers hammer queries while writers execute; every future must finish.

    Also checks that a reader never sees a torn snapshot: the count it reads
    must always be a whole number of executions for that tenant.
    """
    mgr = ScenarioManager()
    h = EVALUATION_TENANTS["acme"]
    stop = threading.Event()
    torn = []

    def writer():
        for _ in range(40):
            mgr.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "acme", h)

    def reader():
        reads = 0
        while not stop.is_set():
            n = len(mgr.get_events_for_customer(h))
            if n % 3:
                torn.append(n)
            mgr.get_history()
            reads += 1
        return reads

    with ThreadPoolExecutor(max_workers=10) as pool:
        readers = [pool.submit(reader) for _ in range(5)]
        writers = [pool.submit(writer) for _ in range(5)]
        _, pending = wait(writers, timeout=DEADLOCK_TIMEOUT_S)
        stop.set()
        _, pending_r = wait(readers, timeout=DEADLOCK_TIMEOUT_S)
        assert not pending and not pending_r, "reader/writer deadlock"
        assert all(f.result() > 0 for f in readers)
    assert torn == [], f"readers observed partial executions: {torn[:5]}"
    assert len(mgr.get_events_for_customer(h)) == 5 * 40 * 3


def test_twenty_concurrent_customer_evaluations(preemptive_scheduler):
    """Twenty distinct customers evaluated at once, one thread each."""
    mgr = ScenarioManager()
    customers = [f"eval-customer-{i:02d}" for i in range(20)]
    assignments = [(c, derive_customer_hash(c)) for c in customers]
    assert len({h for _, h in assignments}) == 20, "hash collision in the test fixture itself"

    results = _dispatch(mgr, assignments, iterations=8)
    for company, h in assignments:
        events = mgr.get_events_for_customer(h)
        assert events and all(e.customer_hash == h and e.company_name == company for e in events)
    assert len(mgr.get_history()) == 20 * 8
    _assert_index_consistent(mgr)
    assert max(ms for _, _, lat in results for ms in lat) < 50.0


def test_worker_failures_leave_state_intact():
    """A worker that raises must not corrupt the manager or take others down.

    A 3-character hash fails SyntheticAuditEvent validation inside the
    generator, before the critical section, so nothing may be stored for it.
    """
    mgr = ScenarioManager()
    good = EVALUATION_TENANTS["globex"]
    jobs = [("globex", good)] * 12 + [("broken", "bad")] * 6
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {
            pool.submit(mgr.execute_scenario, ScenarioType.PROMPT_INJECTION_INTERCEPT, c, h): h
            for c, h in jobs
        }
        failures = [f for f in as_completed(futures, timeout=DEADLOCK_TIMEOUT_S) if f.exception()]
    assert len(failures) == 6
    assert all(futures[f] == "bad" and "customer_hash" in str(f.exception()) for f in failures)
    assert mgr.get_events_for_customer("bad") == []
    assert len(mgr.get_history()) == 12
    assert len(mgr.get_events_for_customer(good)) == 12 * 3
    _assert_index_consistent(mgr)


def test_event_query_latency_under_load():
    """Queries stay sub-millisecond at the median and under 5ms at worst.

    Measured after the tenant holds 50 executions (up to 150 events), which is
    larger than a real demo session produces.
    """
    mgr = ScenarioManager()
    for company, h in EVALUATION_TENANTS.items():
        for i in range(50):
            mgr.execute_scenario(ALL_SCENARIOS[i % 4], company, h)

    samples = []
    for _ in range(300):
        for h in EVALUATION_TENANTS.values():
            t0 = time.perf_counter()
            mgr.get_events_for_customer(h)
            samples.append((time.perf_counter() - t0) * 1000)
    assert statistics.median(samples) < 1.0, f"median query {statistics.median(samples):.4f}ms"
    assert max(samples) < 5.0, f"slowest query {max(samples):.4f}ms"


def test_tenant_lookup_independent_of_other_tenant_volume():
    """The dict lookup is O(1): other tenants' volume must not slow a query.

    Retrieval itself copies the tenant's own list, so it is O(k) in that
    tenant's events. This holds k fixed and grows everyone else 1000-fold.
    """
    def median_query_ms(mgr, h):
        samples = []
        for _ in range(2000):
            t0 = time.perf_counter()
            mgr.get_events_for_customer(h)
            samples.append(time.perf_counter() - t0)
        return statistics.median(samples) * 1000

    target = EVALUATION_TENANTS["kurasi"]
    small = ScenarioManager()
    for _ in range(10):
        small.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", target)

    large = ScenarioManager()
    for _ in range(10):
        large.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", target)
    for i in range(1000):
        noise = f"{i:08x}"
        for _ in range(10):
            large.execute_scenario(ScenarioType.COMPLIANCE_PROOF, "noise", noise)

    baseline_ms, loaded_ms = median_query_ms(small, target), median_query_ms(large, target)
    assert len(large.get_events_for_customer(target)) == 30
    assert loaded_ms < baseline_ms * 3 + 0.005, (
        f"query slowed from {baseline_ms:.4f}ms to {loaded_ms:.4f}ms with 1000 other tenants"
    )


def test_memory_is_linear_and_fully_reclaimed():
    """Memory grows in proportion to executions and is freed with the manager.

    ScenarioManager keeps every event for its lifetime (there is no eviction),
    so memory is bounded by executions retained, not by a fixed ceiling. What
    must hold is that the cost per execution is constant and nothing leaks.
    """
    gc.collect()
    tracemalloc.start()
    try:
        base, _ = tracemalloc.get_traced_memory()
        mgr = ScenarioManager()

        def load(n):
            assignments = [(c, h) for c, h in EVALUATION_TENANTS.items()] * 3
            _dispatch(mgr, assignments, iterations=n)

        load(40)
        first, _ = tracemalloc.get_traced_memory()
        load(40)
        second, _ = tracemalloc.get_traced_memory()
        first_growth, second_growth = first - base, second - first
        assert first_growth > 0
        assert 0.75 < second_growth / first_growth < 1.25, (
            f"non-linear growth: {first_growth}B then {second_growth}B for equal loads"
        )

        del mgr
        gc.collect()
        after, _ = tracemalloc.get_traced_memory()
        assert after - base < 0.05 * (second - base), f"{after - base}B not reclaimed"
    finally:
        tracemalloc.stop()


def test_gc_pauses_stay_small_under_sustained_load():
    """Record every GC pass during a sustained run; none may pause for 20ms+."""
    pauses, starts = [], {}

    def on_gc(phase, info):
        if phase == "start":
            starts[info["generation"]] = time.perf_counter()
        elif info["generation"] in starts:
            pauses.append((info["generation"], (time.perf_counter() - starts.pop(info["generation"])) * 1000))

    gc.callbacks.append(on_gc)
    try:
        mgr = ScenarioManager()
        assignments = [(c, h) for c, h in EVALUATION_TENANTS.items()] * 4
        _dispatch(mgr, assignments, iterations=100)
    finally:
        gc.callbacks.remove(on_gc)
    assert pauses, "no GC ran at all, so this measured nothing"
    worst = max(ms for _, ms in pauses)
    assert worst < 20.0, f"worst GC pause {worst:.2f}ms"


def test_executor_threads_are_cleaned_up():
    """Every worker thread started by the stress run is gone afterwards."""
    before = {t.ident for t in threading.enumerate()}
    run_stress(tenants=5, iterations=10, workers=10)
    leftover = [t for t in threading.enumerate() if t.ident not in before and t.is_alive()]
    assert leftover == [], f"threads left running: {[t.name for t in leftover]}"


def test_api_concurrent_multitenant_isolation():
    """The HTTP surface keeps tenants apart when hit from many threads at once."""
    before = {h: len(GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h)) for h in EVALUATION_TENANTS.values()}
    history_before = len(GLOBAL_SCENARIO_MANAGER.get_history())

    def post(company, h, scenario):
        # No context manager: that would run the app lifespan, which needs Postgres.
        r = EAPClient(app).post("/api/v1/eap/scenarios/execute", json={
            "scenario_type": scenario.value, "company_name": company, "customer_hash": h,
        })
        return r.status_code, r.json()

    jobs = [(c, h, s) for c, h in EVALUATION_TENANTS.items() for s in ALL_SCENARIOS] * 3
    with ThreadPoolExecutor(max_workers=10) as pool:
        responses = list(pool.map(lambda j: post(*j), jobs, timeout=DEADLOCK_TIMEOUT_S))
    assert all(code == 201 for code, _ in responses)
    assert len(GLOBAL_SCENARIO_MANAGER.get_history()) - history_before == len(jobs)

    for company, h in EVALUATION_TENANTS.items():
        events = client.get(f"/api/v1/eap/scenarios/events/{h}").json()
        assert all(e["customer_hash"] == h and e["namespace"] == f"eap-{h}" for e in events)
        assert len(events) - before[h] == 3 * sum(EVENTS_PER_SCENARIO.values())


def run_stress(tenants=20, iterations=50, workers=10):
    """Configurable stress pass. Returns throughput, latency, memory and CPU figures.

    Tenants are spread round-robin over `workers` threads, so with more
    tenants than workers each thread serves several customers.
    """
    mgr = ScenarioManager()
    customers = [(f"stress-tenant-{i:03d}", derive_customer_hash(f"stress-tenant-{i:03d}")) for i in range(tenants)]
    buckets = [customers[i::workers] for i in range(min(workers, tenants))]

    cpu_samples, stop = [], threading.Event()

    def sample_cpu():
        last_cpu, last_wall = time.process_time(), time.perf_counter()
        while not stop.wait(0.01):
            cpu, wall = time.process_time(), time.perf_counter()
            cpu_samples.append(100 * (cpu - last_cpu) / (wall - last_wall))
            last_cpu, last_wall = cpu, wall

    def worker(bucket, barrier):
        barrier.wait(timeout=DEADLOCK_TIMEOUT_S)
        lat = []
        for i in range(iterations):
            for company, h in bucket:
                t0 = time.perf_counter()
                mgr.execute_scenario(ALL_SCENARIOS[i % 4], company, h)
                lat.append((time.perf_counter() - t0) * 1000)
        return lat

    sampler = threading.Thread(target=sample_cpu, name="sles-cpu-sampler", daemon=True)
    barrier = threading.Barrier(len(buckets))
    rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    sampler.start()
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=len(buckets), thread_name_prefix="sles-stress") as pool:
        futures = [pool.submit(worker, b, barrier) for b in buckets]
        _, pending = wait(futures, timeout=DEADLOCK_TIMEOUT_S * 4)
        assert not pending, "stress workers deadlocked"
        latencies = [ms for f in futures for ms in f.result()]
    wall = time.perf_counter() - t0
    stop.set()
    sampler.join(timeout=5)

    _assert_index_consistent(mgr)
    for company, h in customers:
        assert all(e.customer_hash == h for e in mgr.get_events_for_customer(h))

    q = []
    for _, h in customers:
        s = time.perf_counter()
        mgr.get_events_for_customer(h)
        q.append((time.perf_counter() - s) * 1000)

    return {
        "tenants": tenants, "workers": len(buckets), "iterations_per_tenant": iterations,
        "executions": len(latencies), "events": sum(len(mgr.get_events_for_customer(h)) for _, h in customers),
        "wall_s": round(wall, 4), "throughput_exec_per_s": round(len(latencies) / wall, 1),
        "exec_ms": {"p50": round(_percentile(latencies, 50), 4), "p95": round(_percentile(latencies, 95), 4),
                    "p99": round(_percentile(latencies, 99), 4), "max": round(max(latencies), 4)},
        "query_ms": {"p50": round(_percentile(q, 50), 4), "max": round(max(q), 4)},
        "cpu_pct": {"p50": round(_percentile(cpu_samples, 50), 1) if cpu_samples else None,
                    "p95": round(_percentile(cpu_samples, 95), 1) if cpu_samples else None},
        "max_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "max_rss_growth_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - rss_before,
    }


def test_configurable_stress_pass(preemptive_scheduler):
    """Stress pass sized by SLES_STRESS_TENANTS / SLES_STRESS_ITERATIONS / SLES_STRESS_WORKERS.

    Writes the metrics as JSON to SLES_BENCHMARK_OUT when that is set.
    """
    report = run_stress(
        tenants=int(os.environ.get("SLES_STRESS_TENANTS", "20")),
        iterations=int(os.environ.get("SLES_STRESS_ITERATIONS", "50")),
        workers=int(os.environ.get("SLES_STRESS_WORKERS", "10")),
    )
    if os.environ.get("SLES_BENCHMARK_OUT"):
        with open(os.environ["SLES_BENCHMARK_OUT"], "w") as fh:
            json.dump(report, fh, indent=2)
    assert report["executions"] == report["tenants"] * report["iterations_per_tenant"]
    assert report["exec_ms"]["max"] < 50.0, report
    assert report["query_ms"]["max"] < 5.0, report


# ==============================================================================
# SLES-P3-2 gap (filled by SLES-P4-GOV): Server-Sent Events streaming
# ==============================================================================
import asyncio

from pydantic import ValidationError

import scenario_seeding
from scenario_seeding import stream_customer_events
from tenant_isolation import get_tenant_spiffe_id

KURASI_HASH = "6f82ad81"


@pytest.fixture
def fresh_manager(monkeypatch):
    """Point the API at an empty manager so counts are exact regardless of test order."""
    mgr = ScenarioManager()
    monkeypatch.setattr(scenario_seeding, "GLOBAL_SCENARIO_MANAGER", mgr)
    return mgr


def _parse_sse(body: str):
    frames = []
    for block in body.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.splitlines() if line and not line.startswith(":"))
        if "data" in fields:
            frames.append((fields.get("id"), fields.get("event"), json.loads(fields["data"])))
    return frames


def test_sse_stream_replays_only_the_requested_tenant(fresh_manager):
    # The foreign tenant is seeded first: a leak then surfaces at the head of the
    # stream instead of hiding behind the limit (dict insertion order).
    fresh_manager.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "othercorp", "0badf00d")
    fresh_manager.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", KURASI_HASH)
    fresh_manager.execute_scenario(ScenarioType.PROMPT_INJECTION_INTERCEPT, "kurasi", KURASI_HASH)
    # Seeded on the manager, not via POST, so nothing claimed the hash for
    # tenant-a: claim it explicitly or the stream route answers 404.
    eap_tenancy.GLOBAL_TENANT_OWNERSHIP.claim(KURASI_HASH, EAP_TENANT_A)

    resp = client.get(f"/api/v1/eap/scenarios/events/{KURASI_HASH}/stream", params={"limit": 6})
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")
    frames = _parse_sse(resp.text)
    assert [f[0] for f in frames] == ["1", "2", "3", "4", "5", "6"]
    assert {f[1] for f in frames} == {"audit_event"}
    assert {f[2]["customer_hash"] for f in frames} == {KURASI_HASH}
    for _, _, data in frames:
        SyntheticAuditEvent.model_validate(data)


def test_sse_stream_rejects_malformed_customer_hash():
    # Each input reaches the route and is refused by the pattern (422), so a
    # deleted route (404) cannot satisfy this test.  The well-formed hash must
    # be tenant-a's so the Last-Event-ID probe below reaches header validation.
    eap_tenancy.GLOBAL_TENANT_OWNERSHIP.claim(KURASI_HASH, EAP_TENANT_A)
    for bad in ("6F82AD81", "6f82ad8", "zzzzzzzz", "6f82ad811"):
        assert client.get(f"/api/v1/eap/scenarios/events/{bad}/stream").status_code == 422, bad
    assert client.get(f"/api/v1/eap/scenarios/events/{KURASI_HASH}/stream",
                      params={"limit": 1}, headers={"Last-Event-ID": "abc"}).status_code == 422


def test_sse_stream_resumes_after_last_event_id(fresh_manager):
    fresh_manager.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", KURASI_HASH)
    fresh_manager.execute_scenario(ScenarioType.PROMPT_INJECTION_INTERCEPT, "kurasi", KURASI_HASH)
    # Seeded on the manager, not via POST, so nothing claimed the hash for
    # tenant-a: claim it explicitly or the stream route answers 404.
    eap_tenancy.GLOBAL_TENANT_OWNERSHIP.claim(KURASI_HASH, EAP_TENANT_A)
    resp = client.get(f"/api/v1/eap/scenarios/events/{KURASI_HASH}/stream",
                      params={"limit": 3}, headers={"Last-Event-ID": "3"})
    frames = _parse_sse(resp.text)
    assert [f[0] for f in frames] == ["4", "5", "6"]
    assert [f[2]["verdict"] for f in frames] == ["ALLOW", "INTERCEPT", "BLOCK"]


@pytest.mark.asyncio
async def test_sse_live_delivery_is_sub_second_and_tenant_isolated():
    mgr = ScenarioManager()
    mgr.execute_scenario(ScenarioType.COMPLIANCE_PROOF, "othercorp", "0badf00d")  # foreign tenant first
    mgr.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", KURASI_HASH)  # history, not replayed
    stream = stream_customer_events(mgr, KURASI_HASH, replay=False, limit=3)

    async def publish():
        await asyncio.sleep(0.1)
        mgr.execute_scenario(ScenarioType.LATERAL_TRAVERSAL_BLOCKED, "othercorp", "0badf00d")
        published_at = time.perf_counter()
        mgr.execute_scenario(ScenarioType.PROMPT_INJECTION_INTERCEPT, "kurasi", KURASI_HASH)
        return published_at

    publisher = asyncio.create_task(publish())
    first = await asyncio.wait_for(stream.__anext__(), timeout=2.0)
    received_at = time.perf_counter()
    rest = [await asyncio.wait_for(stream.__anext__(), timeout=2.0) for _ in range(2)]
    latency = received_at - await publisher

    assert latency < 1.0, f"live SSE delivery took {latency:.3f}s"
    frames = _parse_sse("".join([first, *rest]))
    assert [f[0] for f in frames] == ["4", "5", "6"]
    assert [f[2]["verdict"] for f in frames] == ["ALLOW", "INTERCEPT", "BLOCK"]
    assert {f[2]["customer_hash"] for f in frames} == {KURASI_HASH}
    with pytest.raises(StopAsyncIteration):
        await stream.__anext__()


@pytest.mark.asyncio
async def test_sse_idle_stream_emits_heartbeat_without_blocking_the_loop():
    stream = stream_customer_events(ScenarioManager(), KURASI_HASH, poll_interval=0.01, heartbeat_interval=0.03)
    ticks = 0

    async def ticker():
        nonlocal ticks
        while True:
            await asyncio.sleep(0.005)
            ticks += 1

    t = asyncio.create_task(ticker())
    frame = await asyncio.wait_for(stream.__anext__(), timeout=1.0)
    t.cancel()
    assert frame == ": keepalive\n\n"
    assert ticks >= 3, "event loop was starved while the stream idled"
    await stream.aclose()


def test_openapi_documents_every_scenario_route_with_models():
    paths = app.openapi()["paths"]
    base = "/api/v1/eap/scenarios"
    assert "requestBody" in paths[f"{base}/execute"]["post"]
    assert "$ref" in json.dumps(paths[f"{base}/execute"]["post"]["responses"]["201"])
    assert "$ref" in json.dumps(paths[f"{base}/events/{{customer_hash}}"]["get"]["responses"]["200"])
    assert "$ref" in json.dumps(paths[f"{base}/history"]["get"]["responses"]["200"])
    stream = paths[f"{base}/events/{{customer_hash}}/stream"]["get"]
    hash_param = next(p for p in stream["parameters"] if p["name"] == "customer_hash")
    assert hash_param["schema"]["pattern"] == scenario_seeding.CUSTOMER_HASH_PATTERN
    # "authorization" is the router-level authenticated_principal header (EAPR-P2-1).
    assert {p["name"] for p in stream["parameters"]} == {
        "customer_hash", "replay", "limit", "last-event-id", "authorization",
    }


# ==============================================================================
# SLES-P4-1 gap (filled by SLES-P4-GOV): kurasi end-to-end evaluation journey
# ==============================================================================

def test_kurasi_evaluation_journey_all_four_archetypes(fresh_manager):
    assert derive_customer_hash("kurasi") == KURASI_HASH
    for scenario in ScenarioType:
        # customer_hash omitted: the API must derive the canonical pilot hash itself
        resp = client.post("/api/v1/eap/scenarios/execute",
                           json={"scenario_type": scenario.value, "company_name": "kurasi"})
        assert resp.status_code == 201, resp.text
        assert resp.json()["customer_hash"] == KURASI_HASH

    events = client.get(f"/api/v1/eap/scenarios/events/{KURASI_HASH}").json()
    assert len(events) == 9
    verdicts = [e["verdict"] for e in events]
    assert (verdicts.count("ALLOW"), verdicts.count("INTERCEPT"), verdicts.count("BLOCK")) == (6, 1, 2)
    assert {e["plane"] for e in events} == {"control", "data", "policy"}
    assert {e["namespace"] for e in events} == {"eap-6f82ad81"}
    assert {e["company_name"] for e in events} == {"kurasi"}
    assert all(e["risk_score"] >= 0.9 for e in events if e["verdict"] != "ALLOW")
    for e in events:
        SyntheticAuditEvent.model_validate_json(json.dumps(e))
    history = client.get("/api/v1/eap/scenarios/history").json()
    assert [h["scenario_type"] for h in history] == [s.value for s in ScenarioType]


def test_kurasi_journey_schema_rejects_invalid_records():
    good = generate_baseline_agent_events("kurasi", KURASI_HASH)[0].model_dump()
    for mutation in ({"risk_score": 1.5}, {"risk_score": -0.1}, {"customer_hash": "6f82ad8"},
                     {"unexpected_field": "x"}):
        with pytest.raises(ValidationError):
            SyntheticAuditEvent.model_validate({**good, **mutation})
    resp = client.post("/api/v1/eap/scenarios/execute",
                       json={"scenario_type": "baseline_agent_flow", "company_name": "kurasi", "admin": True})
    assert resp.status_code == 422
    resp = client.post("/api/v1/eap/scenarios/execute", json={"scenario_type": "rm_rf"})
    assert resp.status_code == 422


# ==============================================================================
# Certification blockers (SLES-P4-GOV). Each test states an invariant from the
# proposal. B1, B2 and B13 were closed by EAPR-P2-1 and are plain tests now;
# the rest the code does not yet meet. strict=True: when the defect is
# fixed the test XPASSes, which fails the run and forces the marker's removal.
# raises=AssertionError: any other exception (e.g. a probe broken by the fix,
# such as a 401 body where a list was expected) fails loudly instead of
# staying silently xfailed.
# ==============================================================================

def test_blocker_execute_requires_authentication(fresh_manager):
    # B1 (closed by EAPR-P2-1): a raw TestClient sends no Authorization header.
    anonymous = TestClient(app)
    resp = anonymous.post("/api/v1/eap/scenarios/execute", json={"company_name": "kurasi"})
    assert resp.status_code == 401
    assert fresh_manager.get_history() == []
    # Positive control: the same body with a real tenant-a token executes.
    assert client.post("/api/v1/eap/scenarios/execute", json={"company_name": "kurasi"}).status_code == 201


def test_blocker_history_is_tenant_scoped(fresh_manager, fresh_tenant_ownership):
    # B2 (closed by EAPR-P2-1): seed two tenants through the API, then each
    # tenant's /history must hold its own execution and nothing else.
    alice_run = client.post("/api/v1/eap/scenarios/execute", json={
        "scenario_type": "baseline_agent_flow", "company_name": "kurasi", "customer_hash": KURASI_HASH,
    })
    assert alice_run.status_code == 201, alice_run.text
    bob_run = client.post("/api/v1/eap/scenarios/execute", headers=eap_bearer("bob"), json={
        "scenario_type": "baseline_agent_flow", "company_name": "othercorp", "customer_hash": "0badf00d",
    })
    assert bob_run.status_code == 201, bob_run.text
    assert len(fresh_manager.get_history()) == 2

    alice_history = client.get("/api/v1/eap/scenarios/history")
    assert alice_history.status_code == 200
    assert [h["customer_hash"] for h in alice_history.json()] == [KURASI_HASH]
    bob_history = client.get("/api/v1/eap/scenarios/history", headers=eap_bearer("bob"))
    assert bob_history.status_code == 200
    assert [h["customer_hash"] for h in bob_history.json()] == ["0badf00d"]


def test_blocker_execute_rejects_non_hex_customer_hash(fresh_manager):
    # B13 (closed by EAPR-P2-1).
    resp = client.post("/api/v1/eap/scenarios/execute",
                       json={"company_name": "kurasi", "customer_hash": "ZZ/..zz!"})
    assert resp.status_code == 422


def test_blocker_event_schema_matches_multiplane_audit_event():
    required = {"event_id", "event_type", "timestamp", "plane", "source_agent",
                "target_resource", "action", "verdict", "risk_score"}
    assert required <= set(SyntheticAuditEvent.model_fields)


def test_blocker_compliance_proof_is_signed():
    proof = generate_compliance_proof_events("kurasi", KURASI_HASH)[0]
    assert str(proof.details.get("signature", "")).startswith("vault:v")


def test_blocker_every_event_carries_spiffe_identity():
    mgr = ScenarioManager()
    for scenario in ScenarioType:
        mgr.execute_scenario(scenario, "kurasi", KURASI_HASH)
    spiffe = get_tenant_spiffe_id(KURASI_HASH)
    assert all(e.details.get("spiffe_id") == spiffe for e in mgr.get_events_for_customer(KURASI_HASH))


def test_blocker_generation_is_deterministic():
    a = [e.model_dump() for e in generate_baseline_agent_events("kurasi", KURASI_HASH)]
    b = [e.model_dump() for e in generate_baseline_agent_events("kurasi", KURASI_HASH)]
    assert a == b


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="SLES multi-tenant stress pass")
    parser.add_argument("--tenants", type=int, default=20)
    parser.add_argument("--iterations", type=int, default=50)
    parser.add_argument("--workers", type=int, default=10)
    parser.add_argument("--switch-interval", type=float, default=1e-6,
                        help="GIL switch interval in seconds; 1e-6 forces heavy preemption")
    args = parser.parse_args()
    sys.setswitchinterval(args.switch_interval)
    print(json.dumps(run_stress(args.tenants, args.iterations, args.workers), indent=2))
