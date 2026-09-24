# SLES — multi-tenant concurrency, isolation and stress characteristics

Card: SLES-P4-2. Subject: `ScenarioManager` in
`d2-signalloom/apps/fe-signalloom/src/scenario_seeding.py`. Suite: the
`SLES-P4-2` section of `src/tests/test_scenario_seeding.py`. Raw run output is in
[`sles-p4-2-stress-transcript.md`](sles-p4-2-stress-transcript.md).

All figures below were measured on one host: 24 cores, Linux 7.1.3, CPython
3.12 (GIL build), run through `uv run --python 3.12`. They show the relative
cost of each operation. They are not a production SLO.

## Isolation guarantees

These are the properties the suite asserts. Each one was run under a 1µs GIL
switch interval (`preemptive_scheduler` fixture), which forces a thread
handoff roughly every bytecode instead of every 5ms.

| Guarantee | How it is enforced in code | Test |
|---|---|---|
| A tenant query returns only its own events | Events are indexed by `customer_hash` in `_events_by_hash`, and the query reads one key | `test_multitenant_scenario_concurrency_and_stress`, `test_twenty_concurrent_customer_evaluations`, `test_api_concurrent_multitenant_isolation` |
| A tenant query returns all of its own events | Same key, and nothing evicts entries | as above; counts reconciled against history |
| Each execution is written whole, as one contiguous block | Index `extend` and history `append` share one `RLock` critical section | `_assert_index_consistent`: every execution's events are a contiguous slice under the right hash, with no duplicates and the total equal to history |
| A worker's executions keep their order in history | History is appended inside the lock, and a worker runs sequentially | per-worker order check in the headline test |
| A failed execution stores nothing | Events are generated and validated *before* the lock, so a `ValidationError` never reaches the store | `test_worker_failures_leave_state_intact` |
| Readers never see a partial execution | Readers copy the list under the same lock | `test_concurrent_readers_and_writers_do_not_deadlock` (the count seen must always be a whole multiple of 3) |
| No deadlock under mixed reads and writes | One lock, never nested with another, and never held across I/O | every executor wait carries a 30s hang guard |
| No leaked threads | `ThreadPoolExecutor` used as a context manager | `test_executor_threads_are_cleaned_up` |

The tenants used are those the card specifies: kurasi `6f82ad81`, acme
`a1b2c3d4` and globex `e5f6a7b8`. The 20-customer test derives its hashes
with `derive_customer_hash` and first asserts they are distinct, so a
collision in the fixture cannot quietly merge two tenants.

## What the suite can and cannot detect

A green concurrency suite proves nothing on its own, so I mutated
`ScenarioManager` four ways and re-ran all 19 tests against each version:

| Mutant | Result | Meaning |
|---|---|---|
| M2: per-event append outside the lock | **killed** (the headline test fails) | interleaved writes are caught by the contiguity check |
| M4: query returns every tenant's events | **killed** (7 tests fail) | cross-tenant leakage is caught |
| M1: lock removed entirely | survived | see below |
| M3: critical section split into two acquisitions | survived | equivalent through the public API: a caller reads events and history in two separate calls, so even the original never offers a joint snapshot |

**The lock is not observable on GIL CPython 3.12.** With the lock removed,
the only unprotected step is `if h not in d: d[h] = []`, followed by
`extend`. A dedicated probe (source and output in transcript §7) had 16 threads race to first-write 200 fresh tenants. It ran for
167 rounds at a 1µs switch interval, 534,400 contended executions, and lost
**0** events. At a 5ms switch interval it ran 290 rounds, also with 0 lost. The
interpreter never preempts between those bytecodes, so no test on this
runtime can tell the locked manager from the unlocked one.

The lock still matters. Free-threaded CPython (3.13t and later) and any
change that adds a yield point inside the critical section would make the
race real. That boundary is **unverified**: `pydantic-core` had no 3.13t
build available, and `uv` could not provide a 3.14t interpreter here. If
the service ever moves to a free-threaded build, re-run M1 there first.

## Benchmark — throughput and latency

Harness: `run_stress(tenants, iterations, workers)` in the test module, also
runnable as a script. Tenants are spread round-robin across workers, and
each execution's latency is measured end to end, including any wait for the
lock.

```bash
cd d2-signalloom/apps/fe-signalloom/src
PYTHONPATH=. uv run --python 3.12 --with pytest --with-requirements requirements.txt \
  python tests/test_scenario_seeding.py --tenants 20 --iterations 50 --workers 10
# pytest form, sized by env and optionally emitting JSON:
SLES_STRESS_TENANTS=20 SLES_STRESS_ITERATIONS=50 SLES_STRESS_WORKERS=10 \
SLES_BENCHMARK_OUT=bench.json pytest tests/test_scenario_seeding.py -k stress
```

| Config (tenants × iterations, workers, switch interval) | Executions | Throughput (exec/s) | Exec p50 | p95 | p99 | max | Query max |
|---|---|---|---|---|---|---|---|
| 3 × 50, 3 workers, 1µs | 150 | 28,161 | 0.029ms | 0.046ms | 1.52ms | 3.33ms | 0.0011ms |
| **20 × 50, 10 workers, 1µs (card scale)** | 1,000 | 22,195 | 0.365ms | 0.816ms | 1.86ms | **3.90ms** | 0.0008ms |
| 100 × 200, 24 workers, 1µs | 20,000 | 12,255–14,565 | 1.21–1.36ms | 2.1–3.0ms | 4.1–5.7ms | **126–151ms** | 0.0052ms |
| 100 × 200, 24 workers, 5ms (default) | 20,000 | ~21,000 | 0.033ms | ~5.0ms | ~17.0ms | **135–137ms** | — |

At the card's scale, every execution finishes in under 4ms, well below the
50ms budget. Queries run in single-digit **microseconds**, three orders of
magnitude below the sub-millisecond target.

### Finding: the 50ms budget breaks at 20,000 retained executions

The latency tail at 100 tenants × 200 iterations reproduced 4 out of 4 runs,
at both switch intervals, so forced preemption is not what causes it. I
split it into two causes with a falsification run (source and output in transcript §8, two runs
with GC on and two with GC off):

| Run | Exec max | Exec p99 | GC passes | Gen-2 passes | Worst GC pause |
|---|---|---|---|---|---|
| GC on | 130.6ms | 14.1ms | 436 | 3 | **115.3ms (gen 2)** |
| GC on | 104.7ms | 13.6ms | 435 | 3 | **103.6ms (gen 2)** |
| GC off | 55.7ms | 15.1ms | 0 | 0 | — |
| GC off | 51.9ms | 14.9ms | 0 | 0 | — |

1. **Gen-2 garbage collection** accounts for about 100ms of the tail. The
   worst GC pause matches the worst execution to within a few milliseconds.
   Gen-2 cost grows with the live heap, and the heap grows because
   `ScenarioManager` retains every event (see Memory below).
2. **GIL queueing** is the remaining ~50ms. With 24 threads contending at the
   default 5ms switch interval, a thread can wait several slices before it
   runs.

Neither cause shows up at card scale. The EAP flow is one evaluator clicking
through four scenarios, which is orders of magnitude below 20,000. The
structural fix is bounded retention, which is owned by the lifecycle cards
and out of scope here: see "Persisting synthetic audit events beyond the
lifecycle of the evaluation environment".

## Memory and GC impact

| Measurement | Result | Test |
|---|---|---|
| Growth per execution | constant: two equal loads grow the traced heap by amounts within ±25% of each other | `test_memory_is_linear_and_fully_reclaimed` |
| Reclamation | after `del mgr; gc.collect()`, less than 5% of peak growth remains | same |
| GC pauses at test load (12 workers × 100 executions) | worst pause under 20ms | `test_gc_pauses_stay_small_under_sustained_load` |
| Max RSS growth, card-scale run | 48–204 KiB | stress JSON `max_rss_growth_kib` |
| Max RSS growth, 20,000 executions | about 110 MiB, roughly 5.5 KiB per execution | stress runs above |
| CPU utilisation, card-scale run (10ms samples) | p50 136%, p95 153% of one core | stress JSON `cpu_pct` |

**Memory is linear and unbounded, not bounded.** `ScenarioManager` has no
eviction, and the process-wide `GLOBAL_SCENARIO_MANAGER` keeps every event
for the life of the pod. The suite asserts only what is actually true:
constant cost per execution, and full reclamation when the manager is
dropped. It does not claim a ceiling that the code does not have. Resource
use is proportional to executions retained, not to the number of active
evaluators.

A CPU utilisation above 100% on a GIL build is not a contradiction.
`time.process_time()` counts CPU across all threads, and threads blocked in
the barrier and the lock wait in the kernel, which is also counted.

## Tenant lookup complexity

`get_events_for_customer` is an O(1) dict lookup followed by an O(k) copy of
that tenant's own list. `test_tenant_lookup_independent_of_other_tenant_volume`
keeps k fixed at 30 events and adds 1,000 other tenants holding 10,000 events
between them. The median query time must stay within 3× of the unloaded
baseline. So a lookup is constant in *other* tenants' volume and linear in
the tenant's own volume, and the test asserts exactly that, no more.

## Not applicable

The card asks about database connection pool stability. `ScenarioManager`
is purely in memory and opens no database connections, so there is no pool
to stress. The concurrent API test deliberately avoids `with
TestClient(app)`, because that runs the app lifespan, which opens the
Postgres pool.
