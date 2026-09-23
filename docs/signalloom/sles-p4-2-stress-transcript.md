# SLES-P4-2 — stress test execution transcript

Captured 2026-09-23 in the SLES-P4-2 worktree (base `c5711d7f`, `integration/sles-v0.1.0`), running from `d2-signalloom/apps/fe-signalloom/src` with
`UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache uv run --python 3.12 --with pytest --with pytest-asyncio --with-requirements requirements.txt python -m pytest -p no:cacheprovider`.
Analysis: [`sles-concurrency.md`](sles-concurrency.md).

## 1. Prior-work baseline (base commit, before any change)

```
tests/test_scenario_seeding.py::test_baseline_agent_events_generation PASSED [ 12%]
tests/test_scenario_seeding.py::test_prompt_injection_intercept_events PASSED [ 25%]
tests/test_scenario_seeding.py::test_lateral_traversal_blocked_events PASSED [ 37%]
tests/test_scenario_seeding.py::test_compliance_proof_events PASSED      [ 50%]
tests/test_scenario_seeding.py::test_scenario_manager_execution_and_storage PASSED [ 62%]
tests/test_scenario_seeding.py::test_api_execute_scenario_endpoint PASSED [ 75%]
tests/test_scenario_seeding.py::test_api_get_customer_events_endpoint PASSED [ 87%]
tests/test_scenario_seeding.py::test_api_get_history_endpoint PASSED     [100%]
======================== 8 passed, 2 warnings in 1.03s =========================
```

## 2. Required tests (final tree)

The card-specified `import fe_signalloom` probe exits 1 because no such module exists in the repo. The substitute probe imports the module under test.

```
$ pytest tests/test_scenario_seeding.py -k test_scenario_manager_execution_and_storage -v
tests/test_scenario_seeding.py::test_scenario_manager_execution_and_storage PASSED [100%]
================= 1 passed, 18 deselected, 1 warning in 0.96s ==================
exit=0
$ pytest tests/test_scenario_seeding.py -k test_api_execute_scenario_endpoint -v
tests/test_scenario_seeding.py::test_api_execute_scenario_endpoint PASSED [100%]
================= 1 passed, 18 deselected, 1 warning in 1.15s ==================
exit=0
$ pytest tests/test_scenario_seeding.py -k test_api_get_history_endpoint -v
tests/test_scenario_seeding.py::test_api_get_history_endpoint PASSED     [100%]
================= 1 passed, 18 deselected, 1 warning in 1.01s ==================
exit=0
$ SLES_BENCHMARK_OUT=<file> pytest tests/test_scenario_seeding.py -v
tests/test_scenario_seeding.py::test_baseline_agent_events_generation PASSED [  5%]
tests/test_scenario_seeding.py::test_prompt_injection_intercept_events PASSED [ 10%]
tests/test_scenario_seeding.py::test_lateral_traversal_blocked_events PASSED [ 15%]
tests/test_scenario_seeding.py::test_compliance_proof_events PASSED      [ 21%]
tests/test_scenario_seeding.py::test_scenario_manager_execution_and_storage PASSED [ 26%]
tests/test_scenario_seeding.py::test_api_execute_scenario_endpoint PASSED [ 31%]
tests/test_scenario_seeding.py::test_api_get_customer_events_endpoint PASSED [ 36%]
tests/test_scenario_seeding.py::test_api_get_history_endpoint PASSED     [ 42%]
tests/test_scenario_seeding.py::test_multitenant_scenario_concurrency_and_stress PASSED [ 47%]
tests/test_scenario_seeding.py::test_concurrent_readers_and_writers_do_not_deadlock PASSED [ 52%]
tests/test_scenario_seeding.py::test_twenty_concurrent_customer_evaluations PASSED [ 57%]
tests/test_scenario_seeding.py::test_worker_failures_leave_state_intact PASSED [ 63%]
tests/test_scenario_seeding.py::test_event_query_latency_under_load PASSED [ 68%]
tests/test_scenario_seeding.py::test_tenant_lookup_independent_of_other_tenant_volume PASSED [ 73%]
tests/test_scenario_seeding.py::test_memory_is_linear_and_fully_reclaimed PASSED [ 78%]
tests/test_scenario_seeding.py::test_gc_pauses_stay_small_under_sustained_load PASSED [ 84%]
tests/test_scenario_seeding.py::test_executor_threads_are_cleaned_up PASSED [ 89%]
tests/test_scenario_seeding.py::test_api_concurrent_multitenant_isolation PASSED [ 94%]
tests/test_scenario_seeding.py::test_configurable_stress_pass PASSED     [100%]
======================== 19 passed, 1 warning in 1.67s =========================
exit=0
$ python3 -c "import fe_signalloom; ..."  (card-specified probe)
ModuleNotFoundError: No module named 'fe_signalloom'
exit=1
$ python -c "import scenario_seeding; ..."  (substitute probe)
Concurrency stress test harness active
exit=0
```

## 3. Every test in isolation (order-independence check)

```
test_baseline_agent_events_generation :: 1 passed, 1 warning in 1.00s
test_prompt_injection_intercept_events :: 1 passed, 1 warning in 1.01s
test_lateral_traversal_blocked_events :: 1 passed, 1 warning in 1.03s
test_compliance_proof_events :: 1 passed, 1 warning in 1.05s
test_scenario_manager_execution_and_storage :: 1 passed, 1 warning in 1.01s
test_api_execute_scenario_endpoint :: 1 passed, 1 warning in 1.00s
test_api_get_customer_events_endpoint :: 1 passed, 1 warning in 1.05s
test_api_get_history_endpoint :: 1 passed, 1 warning in 1.03s
test_multitenant_scenario_concurrency_and_stress :: 1 passed, 1 warning in 1.08s
test_concurrent_readers_and_writers_do_not_deadlock :: 1 passed, 1 warning in 1.07s
test_twenty_concurrent_customer_evaluations :: 1 passed, 1 warning in 1.03s
test_worker_failures_leave_state_intact :: 1 passed, 1 warning in 1.04s
test_event_query_latency_under_load :: 1 passed, 1 warning in 1.08s
test_tenant_lookup_independent_of_other_tenant_volume :: 1 passed, 1 warning in 2.21s
test_memory_is_linear_and_fully_reclaimed :: 1 passed, 1 warning in 3.70s
test_gc_pauses_stay_small_under_sustained_load :: 1 passed, 1 warning in 1.42s
test_executor_threads_are_cleaned_up :: 1 passed, 1 warning in 1.33s
test_api_concurrent_multitenant_isolation :: 1 passed, 1 warning in 1.39s
test_configurable_stress_pass :: 1 passed, 1 warning in 1.15s
```

## 4. Benchmark JSON — pytest stress pass at card scale

```json
{
  "tenants": 20,
  "workers": 10,
  "iterations_per_tenant": 50,
  "executions": 1000,
  "events": 2280,
  "wall_s": 0.0451,
  "throughput_exec_per_s": 22194.5,
  "exec_ms": {
    "p50": 0.365,
    "p95": 0.8163,
    "p99": 1.8562,
    "max": 3.897
  },
  "query_ms": {
    "p50": 0.0004,
    "max": 0.0008
  },
  "cpu_pct": {
    "p50": 136.0,
    "p95": 153.1
  },
  "max_rss_kib": 160928,
  "max_rss_growth_kib": 48
}
```

## 5. Benchmark — script runs

```
{"tenants": 3, "workers": 3, "iterations_per_tenant": 50, "executions": 150, "events": 342, "wall_s": 0.0053, "throughput_exec_per_s": 28161.4, "exec_ms": {"p50": 0.0289, "p95": 0.0458, "p99": 1.5158, "max": 3.3304}, "query_ms": {"p50": 0.0007, "max": 0.0011}, "cpu_pct": {"p50": null, "p95": null}, "max_rss_kib": 121316, "max_rss_growth_kib": 1536}

### --tenants 20 --iterations 50 --workers 10
{
  "tenants": 20,
  "workers": 10,
  "iterations_per_tenant": 50,
  "executions": 1000,
  "events": 2280,
  "wall_s": 0.0505,
  "throughput_exec_per_s": 19816.8,
  "exec_ms": {
    "p50": 0.3787,
    "p95": 1.0448,
    "p99": 2.8072,
    "max": 4.2007
  },
  "query_ms": {
    "p50": 0.0004,
    "max": 0.0009
  },
  "cpu_pct": {
    "p50": 133.6,
    "p95": 162.3
  },
  "max_rss_kib": 127128,
  "max_rss_growth_kib": 6528
}
### --tenants 100 --iterations 200 --workers 24
{
  "tenants": 100,
  "workers": 24,
  "iterations_per_tenant": 200,
  "executions": 20000,
  "events": 45000,
  "wall_s": 1.3732,
  "throughput_exec_per_s": 14564.8,
  "exec_ms": {
    "p50": 1.2086,
    "p95": 2.14,
    "p99": 4.1246,
    "max": 126.2944
  },
  "query_ms": {
    "p50": 0.0033,
    "max": 0.0052
  },
  "cpu_pct": {
    "p50": 128.4,
    "p95": 136.7
  },
  "max_rss_kib": 231812,
  "max_rss_growth_kib": 111704
}
### si=1e-6
{'p50': 1.3567, 'p95': 3.0078, 'p99': 5.6598, 'max': 143.217} thr 12254.7 rss_growth 110500
### si=1e-6
{'p50': 1.2477, 'p95': 2.4364, 'p99': 4.3101, 'max': 151.1977} thr 13246.8 rss_growth 110404
### si=0.005
{'p50': 0.0332, 'p95': 4.9825, 'p99': 16.989, 'max': 136.7968} thr 21117.6 rss_growth 110992
### si=0.005
{'p50': 0.0333, 'p95': 5.1662, 'p99': 16.9555, 'max': 135.1856} thr 20978.6 rss_growth 111804
```

## 6. Mutation results (19 tests against each mutant of ScenarioManager)

```
M1_no_lock :: 19 passed, 1 warning in 1.64s
M2_per_event_unlocked :: 1 failed, 18 passed, 1 warning in 1.69s
FAILED tests/test_scenario_seeding.py::test_multitenant_scenario_concurrency_and_stress
M3_split_critical_section :: 19 passed, 1 warning in 1.94s
M4_cross_tenant_leak :: 7 failed, 12 passed, 1 warning in 2.06s
FAILED tests/test_scenario_seeding.py::test_multitenant_scenario_concurrency_and_stress
FAILED tests/test_scenario_seeding.py::test_twenty_concurrent_customer_evaluations
FAILED tests/test_scenario_seeding.py::test_worker_failures_leave_state_intact
FAILED tests/test_scenario_seeding.py::test_tenant_lookup_independent_of_other_tenant_volume
FAILED tests/test_scenario_seeding.py::test_executor_threads_are_cleaned_up
FAILED tests/test_scenario_seeding.py::test_api_concurrent_multitenant_isolation
FAILED tests/test_scenario_seeding.py::test_configurable_stress_pass
```

## 7. Lock-observability race probe (M1 applied)

```
switchinterval=1e-6 rounds=167 lost_events=0
switchinterval=0.005 rounds=290 lost_events=0
```

```python
import sys, threading, time
from concurrent.futures import ThreadPoolExecutor
from scenario_seeding import ScenarioManager, ScenarioType
sys.setswitchinterval(float(sys.argv[1]))
lost_total = 0; t_end = time.time() + 20; rounds = 0
while time.time() < t_end:
    mgr = ScenarioManager(); hashes = [f"{i:08x}" for i in range(200)]
    b = threading.Barrier(16)
    def w():
        b.wait()
        for h in hashes: mgr.execute_scenario(ScenarioType.COMPLIANCE_PROOF, "x", h)
    with ThreadPoolExecutor(16) as p: [f.result() for f in [p.submit(w) for _ in range(16)]]
    lost_total += 16*200 - sum(len(mgr.get_events_for_customer(h)) for h in hashes); rounds += 1
print(f"switchinterval={sys.argv[1]} rounds={rounds} lost_events={lost_total}")
```

## 8. GC falsification probe (100 tenants × 200 iterations, 24 workers)

```
gc_off exec_max_ms 55.6957 p99 15.0537 gc_passes 0 gen2_passes 0 worst_gc None
gc_on exec_max_ms 130.5917 p99 14.0989 gc_passes 436 gen2_passes 3 worst_gc (2, 115.34173809923232)
gc_off exec_max_ms 51.8832 p99 14.9437 gc_passes 0 gen2_passes 0 worst_gc None
gc_on exec_max_ms 104.7147 p99 13.5841 gc_passes 435 gen2_passes 3 worst_gc (2, 103.61948399804533)
```

```python
import gc, sys, time
sys.path.insert(0, "tests")
from test_scenario_seeding import run_stress
mode = sys.argv[1]
pauses = []; st = {}
def cb(phase, info):
    g = info["generation"]
    if phase == "start": st[g] = time.perf_counter()
    else: pauses.append((g, (time.perf_counter() - st.pop(g)) * 1000))
if mode == "gc_off": gc.disable()
else: gc.callbacks.append(cb)
d = run_stress(100, 200, 24)
gc.enable()
worst = max(pauses, key=lambda p: p[1]) if pauses else None
g2 = [p for g, p in pauses if g == 2]
print(mode, "exec_max_ms", d["exec_ms"]["max"], "p99", d["exec_ms"]["p99"], "gc_passes", len(pauses), "gen2_passes", len(g2), "worst_gc", worst)
```

## 9. Full fe-signalloom suite (regression check)

```
1 failed, 1408 passed, 83 skipped, 3 warnings in 221.58s (0:03:41)
FAILED tests/test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision
  AssertionError: 13 mutating route(s) neither write an audit event nor declare why they should not
```

That failure predates this card. The only code this card changes is `tests/test_scenario_seeding.py`, and the 13 routes named come from the SLEA/SLED/SLES/SLET modules already merged at the base commit (`environment_lifecycle.py`, `environment_routing.py` and others).
