# SLED Phase 2 Governor Certification — ReaperDaemon

Card: `SLED-P2-GOV`. Date: 2026-09-23. Integration branch: `integration/sled-v0.1.0`.

## Verdict

**NOT CERTIFIED. Status: fail. Next phase blocked (`proceed=no`).**

The reaper passes four of the five axes: event-loop safety at the measured
load, fault isolation, cancellation, and concurrency/memory. It fails the fifth,
telemetry. `SLED-P2-2` (reaper telemetry, Prometheus metrics and health probes)
has no commit and no errata block, although the board shows it as done. The
metrics that do exist come from `SLED-P2-1` and are a JSON dict, not Prometheus
exposition.

| Axis | Result | Evidence |
|---|---|---|
| Sub-second reconciliation at a 1000-environment fleet | PASS | 9.5 ms first pass, about 1.3 ms steady state |
| Event loop not blocked during a pass | PASS (uncontended) | Worst loop lag 1.66 ms |
| Event loop not blocked under lock contention | **FAIL (D3)** | Loop stalled for 390 ms |
| Backend exceptions do not stop the loop | PASS | 25 injected faults; the task survived and completed 5 more cycles |
| Per-environment fault isolation and DLQ | PASS | 9 of 10 drained; the faulty environment reached the DLQ |
| Manual reaps alongside scheduled reaps | PASS | Zero overlapping passes in 50 racing calls; each environment drained once |
| Cancellation at shutdown | PASS | 50 start/stop cycles; no leaked tasks; worst stop 0.06 ms |
| Stop while a manual pass is in flight | PASS | No deadlock; the pass completed |
| 1000 concurrent lifecycle queries plus 20 manual reaps | PASS | All 1020 returned 200 in 0.188 s |
| Threaded heartbeats racing reaper passes (32 threads × 200 passes) | PASS | Zero errors; no environment drained twice |
| Memory over continuous execution | PASS | Traced heap plateaus at about 1.17 MB after 30k passes |
| OpenMetrics compliance | **FAIL (D1)** | `/metrics` returns `application/json` |
| Memory watchdog measures the right quantity | **FAIL (D2)** | Reports 431 MB when current RSS is 131.7 MB |
| Health status reflects task liveness | **FAIL (D5)** | Reports `is_running=True` after the task has died |
| A malformed record cannot starve the fleet | **FAIL (D4, low)** | The whole pass aborts and nothing reaches the DLQ |

## What was integrated

The prerequisites were merged in dependency order into `integration/sled-v0.1.0`
with `--no-ff`. Both merges were clean.

| Card | Commit | Merge |
|---|---|---|
| `SLED-P2-PRE` | `a552419496aadba87c0b7992b0074abfc0e22e46` | `0ee809a9` |
| `SLED-P2-1` | `600e51346c540cd4a183b8c9f4be432118305ecd` | `3b2be825205e11fb7b290f8ec608a01eee4822b4` |
| `SLED-P2-2` | none found across `git log --all` or any worktree | not merged |

## Method

Every claim here cites a probe in
`d2-signalloom/apps/fe-signalloom/src/tests/test_sled_p2_certification.py`.
Properties the daemon has are plain tests. Each defect is written as a test of
the *correct* behaviour and marked `xfail(strict=True)`. When a defect is fixed,
its test XPASSes and the suite goes red, which forces this record to be updated.
The raw transcript is in `docs/signalloom/evidence/sled-p2-gov-probes.txt`.

Test results:

- **Certification and lifecycle suites:** 35 passed, 5 strict-xfailed, 0 failed.
- **`tests/test_environment_lifecycle.py` (required test):** 23 of 23 passed.
- **Full fe-signalloom suite:** 1417 passed, 83 skipped, 5 xfailed, rc=0.

## 1. Event-loop safety audit

- `ReaperDaemon` is an `asyncio.Task` created in the FastAPI `lifespan` (`main.py`).
  It is stopped by `cancel()` and then `wait_for`, and a drain wait covers any
  manual pass still in flight.
- `run_reconciliation_pass` calls the synchronous `evaluate_reaping` directly on
  the event loop. Today that call is pure in-memory work, so the design is safe.
  At 1000 environments a pass costs about 1.3 ms and the worst loop lag seen was
  1.66 ms.
- **D3, medium.** `evaluate_reaping` takes the manager lock with
  `threading.RLock.acquire(timeout=5)`, and it does so on the loop thread.
  Threadpool callers can hold that lock, for example the `SLED-P3-1` teardown
  route. When they do, the whole event loop blocks for as long as the lock is
  held, up to 5 s. The probe held the lock for 400 ms and saw a 390 ms stall.
- **Phase 3 consequence of D3.** Phase 3 intends to have the reaper invoke the
  subprocess-based teardown (5 s per stage in `SLED-P3-1`, 10 s ceiling per shared
  patterns). If that happens inside `evaluate_reaping`, it runs on the loop and
  stalls every API request. The pass must move off the loop with
  `await asyncio.to_thread(...)` before that wiring lands.
- `RLock` gives no exclusion between coroutines, because they all share one
  thread. This is safe only because nothing awaits while the lock is held. Keep
  it that way.

## 2. Fault-injection resilience report

- A pass that raises any `Exception` is caught in `_loop`. The loop logs it,
  sleeps `min_interval`, and continues. 25 consecutive `ConnectionError`s were
  injected and the task stayed alive and then completed 5 clean cycles.
- `CancelledError` breaks the loop cleanly. `SystemExit` and `KeyboardInterrupt`
  are re-raised out of the loop by asyncio, which is correct. Any other
  `BaseException` ends the task, and the exception is retrievable from it rather
  than looped over.
- Per-environment faults are isolated. With `TimeoutError` injected on 1 of 10
  environments, the other 9 drained and the faulty one reached the DLQ with
  `ERR_TRANSITION_FAILED` after three cycles.
- **D4, low.** The priority sort key, the error branch that rebuilds the record,
  and the alert dispatch all sit outside the per-record `try`. If any of them
  raises, the whole pass aborts, and it aborts again on every cycle. Healthy
  environments are then never reaped, and because the failure counter never
  increments, nothing reaches the DLQ. Validated API paths cannot produce such a
  record today; `model_construct` can.
- **D5, medium.** `get_status()` and `/reaper/status` read `is_running` from a
  flag rather than from `self._task.done()`. A reaper whose task has died
  therefore reports itself as running, so a liveness probe built on this
  endpoint would never fire.

## 3. Prometheus metric compliance inspection

`GET /api/v1/eap/lifecycle/metrics` returns `content-type: application/json` with
these keys:
`signalloom_eap_active_environments`, `signalloom_eap_dlq_total`,
`signalloom_eap_reaped_total`, `signalloom_eap_reaper_cycles_total`,
`signalloom_eap_reaper_duration_seconds`.

**D1, high: not compliant with OpenMetrics or the Prometheus text format.**

- There are no `# TYPE` or `# HELP` lines and no `# EOF` terminator. A Prometheus
  scrape of this endpoint fails to parse.
- `signalloom_eap_reaper_duration_seconds` is the last pass's duration as a single
  float, not a histogram. No quantile or SLO can be computed from it.
- `signalloom_eap_reaped_total` is a dict keyed by `"action:reason"` strings where
  it should be a counter with `action` and `reason` labels.
- `signalloom_eap_active_environments` and `signalloom_eap_dlq_total` are
  overwritten each cycle. The second is named as a counter but behaves as a gauge.
- **Cardinality is bounded, so there is no metric memory leak.** `reaped_total`
  is keyed only by action×reason, a set of fewer than 10 values that never
  includes a customer hash.

This is the undelivered `SLED-P2-2` scope. The out-of-scope rule forbids
*disabling* reaper telemetry export. It does not apply here, because no
Prometheus export was ever delivered.

## 4. Memory and coroutine leak inspection

- **Coroutines.** After 50 start/stop cycles, `asyncio.all_tasks()` returns to its
  baseline. `start()` is idempotent and returns `False` if the reaper is already
  running.
- **Heap.** A 200-environment fleet ran with logging disabled. The traced heap
  grew by +379 KB at 5k passes, +713 KB at 10k, +1.08 MB at 20k and +1.17 MB at
  30k. The growth slows toward a plateau, which fits a bounded cache rather than
  a per-pass leak. 30k passes is about 10 days at the 30 s base interval. The
  audit log is capped at 1000 events.
- **D2, medium.** `MemoryWatchdog.get_rss_bytes()` reads `ru_maxrss`. That is the
  *peak* RSS, and it never decreases, so the watchdog cannot see memory recover
  or tell a leak from a one-off spike. In one probe it reported 431 MB while the
  current RSS (`VmRSS`) was 131.7 MB. The 50 MB bound also sits below the peak
  RSS of any FastAPI worker measured here (84.6 MB standalone, 129.6 MB under
  pytest). The watchdog therefore logs a WARNING on every pass and reports
  `memory_healthy=false` permanently. Under pytest, its log records were the
  entire 3.5 MB of apparent heap growth.

## 5. High-concurrency benchmark transcript

- **1000 concurrent `GET /environments/{hash}` plus 20 concurrent `POST /reap-now`,
  with the scheduled loop running at 10 ms.** All 1020 responses returned 200 in
  0.188 s, the reaper completed 21 cycles, and every expired environment drained
  exactly once.
- **50 racing `run_reconciliation_pass` calls against the scheduled loop.** A
  re-entrancy probe inside `evaluate_reaping` saw zero overlapping passes. The
  per-daemon `asyncio.Lock` serialises manual and scheduled passes.
- **32 threads issuing `record_activity` against 200 reaper passes.** Zero errors,
  every state remained a valid enum value, and no environment drained twice.

## Required remediation before re-certification

| ID | Severity | Owner | Fix |
|---|---|---|---|
| D1 | high | `SLED-P2-2`, re-run | Real Prometheus or OpenMetrics text exposition: duration histogram, labelled counters, and correct gauge versus counter types. |
| D3 | medium | Before `SLED-P3-GOV` wires the teardown into the reaper | Run `evaluate_reaping` via `asyncio.to_thread` so the manager lock and the teardown stages never block the loop. |
| D5 | medium | `SLED-P2-2` (health probes) | Derive `is_running` from task liveness and surface a dead task as unhealthy. |
| D2 | medium | `SLED-P2-2` | Read current RSS (`/proc/self/statm` or `VmRSS`) and set a bound above the worker's measured baseline. |
| D4 | low | Next reaper change | Move the priority computation and the error-branch record rebuild inside per-record isolation. |

Each fix flips its strict-xfail probe to XPASS. Re-certification means removing
those markers and seeing the suite pass.

## Prompt-contract compliance

- **Shared-pattern canonical identity.** `kurasi` resolves to `6f82ad81`. The
  `kusari` spelling in the proposal is wrong; `SLED-P3-1` already recorded this.
- **Audit event schema.** `ReaperAuditEvent` carries all eight required fields,
  asserted by the existing `test_nanosecond_precision_timestamps_and_audit_schema`.
- **`threading.RLock` registries.** Present in the manager, the DLQ, the
  scheduler, the notifier and the metrics.
- **Bounded execution.** The lock timeout is 5 s. The 10 s per-stage teardown
  ceiling is Phase 3 scope and is not exercised by the reaper yet.
