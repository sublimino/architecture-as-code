# SLED-P2-PRE — ReaperDaemon Background Scheduler & Async Safety Preflight

| Field | Value |
| :--- | :--- |
| Card | `SLED-P2-PRE` (Preflight, board SLED, kanban task `bb360`) |
| Base | `integration/sled-v0.1.0` @ `3b73e570` |
| Subject | `d2-signalloom/apps/fe-signalloom/src/environment_lifecycle.py`, `main.py` lifespan |
| Date | 2026-09-23 |
| Verdict | **PASS (preflight)** — the audit is complete and evidenced. The *implementation* it audits has no reaper loop; the gaps are specified in §6 for SLED-P2-1 / P2-2. |

This preflight answers one question for the implementation cards: *how must a periodic reaper live inside the Signal Loom FastAPI process so that it never freezes the event loop, never dies silently, and never leaves an environment half-reaped on SIGTERM?* Every behavioural claim below comes from a probe run in this session, and the probes are reproducible from §8.

---

## 1. Headline findings

1. **There is no ReaperDaemon.** `environment_lifecycle.py` imports `asyncio` and never uses it, and `main.py`'s `lifespan` starts no task. Reaping happens only when someone calls `POST /api/v1/eap/lifecycle/reap-now`. This matches the council's gap finding.
2. **`asyncio.shield` protects only work that someone keeps awaiting — measured.** In the `shieldcancel` probe, lifespan cancelled the outer reaper and returned without awaiting the shielded inner teardown. That work was lost at `shred:start`, the same outcome as the unshielded variant, and the inner task never even logged a cancellation. In the `shieldawait` variant, lifespan held a reference to the inner task and awaited it, and teardown completed through `namespace:done`. So the rule is **drain-then-await**: the pattern in §5.1, or awaiting the shielded inner task. `task.cancel()` followed by a return orphans the work. Checkpointing plus idempotent resume is still **mandatory**, but for reasons the in-process probes do *not* cover: SIGKILL when the grace period expires, OOMKill (`limits.memory: 256Mi`), node loss, process crash, and a second SIGINT (uvicorn sets `force_exit`, which skips lifespan shutdown entirely). No in-process pattern survives any of these.
3. **An uncaught exception kills the reaper silently while the pod stays healthy.** In the `naked` probe the task died on tick 3 and `/livez` kept answering in about 1 ms. Nothing was logged until shutdown retrieved the exception. Liveness cannot see a dead reaper; the loop needs a supervisor.
4. **A blocking call in the loop starves every request.** One `time.sleep(2)` raised `/livez` latency from 0.0006 s to **1.96–1.98 s** (two runs). The deployment sets no `timeoutSeconds` on its probes, so the kubelet default of 1 s applies. A blocking reaper therefore turns directly into failed liveness probes and a restart loop.
5. **Lease expiry is enforced by the reaper's cadence, not by the lease.** One heartbeat on a lease that had expired 20 s earlier returned `extended=True ttl_remaining_s=3579`, and the next reaper pass returned `[]`. At a 30 s cadence, any heartbeat that lands up to 30 s after expiry revives the lease.
6. **The teardown cannot run from this pod as designed.** The image copies only `src/` (Dockerfile line 11), so `scripts/eap/tailscale-eap-env.sh` is not present. The root filesystem is read-only, and neither `tailscale`, `kubectl` nor a Kubernetes client is in `requirements.txt`. The reaper has to *delegate* teardown (§5.5), not shell out.
7. **Lease state is in-process memory.** `GLOBAL_LIFECYCLE_MANAGER` is a module-level dict. Every pod restart forgets every lease, including the environments that most need reaping. After a crash those become orphans that no later pass can find.
8. **CPU is not the constraint.** An idle evaluation pass over 1,000 environments costs 0.451 ms, a 0.0015 % duty cycle at 30 s. Tune the cadence for correctness and teardown I/O, not CPU.

---

## 2. Prior-work verification table

| # | Artifact | Probe | Result |
| :-- | :--- | :--- | :--- |
| V1 | `src/environment_lifecycle.py` (17,581 B) | `wc -c` | **17581** — matches card claim |
| V2 | States ACTIVE/DRAINING/TERMINATED (+PROVISIONING/WARMING) | Read L31-60 | Present; `VALID_TRANSITIONS` graph enforced in `transition_state` |
| V3 | Heartbeat lease renewal with ceiling | Read L210-264 | Present; `min(candidate, max_lifetime_expires_at)` enforces the 8 h cap |
| V4 | `ttl_remaining_seconds` | Read L79-83 | Present (property, clamps at 0) |
| V5 | `src/tests/test_environment_lifecycle.py` (8 tests) | `uv run … pytest tests/test_environment_lifecycle.py -v` | **8 passed in 1.24s** |
| V6 | API wiring in `main.py` | `rg install_environment_lifecycle_api main.py` | L15 import, L48 `install_environment_lifecycle_api(app)` — wired |
| V7 | Background reaper loop | `rg 'create_task\|ensure_future\|BackgroundTasks\|Thread\|while ' environment_lifecycle.py`; Read `main.py` L28-33 | **ABSENT.** `asyncio` imported, unused; `lifespan` only inits the DB pool and adapters |
| V8 | Teardown invokes `tailscale-eap-env.sh` | Read `evaluate_reaping` L291-322 | **ABSENT.** DRAINING→TERMINATED is a pure state flip; `teardown_stages_completed` is never appended to |
| V9 | Teardown script reachable from the pod | Dockerfile `COPY src/ .`; deployment `readOnlyRootFilesystem: true` | **NOT REACHABLE** — script not in image; no tailscale/k8s client dependency |
| V10 | Prometheus metrics | `rg prometheus requirements.txt src/environment_lifecycle.py` | **ABSENT** — `prometheus_client` not a dependency |
| V11 | Outbound webhook dispatch / crypto-shred / kusari suites | card inventory | **ABSENT** (council-confirmed; out of P2-PRE scope — P3/P4) |
| V12 | Lifecycle endpoints require auth | `test_api_lifecycle_full_flow` calls `POST /reap-now`, `/register`, `/heartbeat` on the real `main.app` with **no Authorization header** and passes; `HostCredentialScopeMiddleware` only restricts *host-scoped* bearer tokens | **UNAUTHENTICATED** — see §7 R3 |
| V13 | `terminationGracePeriodSeconds` | `rg terminationGracePeriod base/` | **Unset** → Kubernetes default 30 s |
| V14 | Worker / replica topology | Dockerfile CMD `--workers 1`; `deployment.yaml` `replicas: 1` | Single writer today (the in-memory design depends on this) |

**Kept as verified:** V1–V6 (state machine, heartbeat cap, TTL property, tests, routing). **Gaps to implement:** V7–V10, V12–V13.

---

## 3. Empirical probe results

A standalone FastAPI + uvicorn 0.30.6 app (versions pinned to `requirements.txt`) ran each loop variant with a four-stage, 1.6 s teardown. A real `kill -TERM` (or `-INT`) was sent at a chosen moment. The source is in §8.

| Variant | Shutdown | Signal during | `/livez` max latency | Final stage | Exit | Verdict |
| :--- | :--- | :--- | ---: | :--- | :-- | :--- |
| `good` | drain + await | idle (after tick 4) | 0.0011 s | `namespace:done` | 143 | clean in 0.160 s |
| `good` | drain + await | **teardown** (`tailscale:start`) | 0.0007 s | **`namespace:done`** | 143 | completed remaining stages in 0.867 s |
| `good` | drain + await | teardown, **SIGINT** | 0.0006 s | `namespace:done` | 0 † | same drain path as SIGTERM |
| `naked` | drain | idle | 0.0007 s | — | 143 | **task dead since tick 3, pod healthy, silent** |
| `blocking` | drain | idle | **1.958 s** | — | 143 | event loop starved |
| `unshielded` | `task.cancel()` | teardown | 0.0008 s | **`shred:start`** | 143 | **half-reaped** (`teardown inner cancelled during shred`) |
| `shieldcancel` | `task.cancel()`; inner shielded, **not awaited** | teardown | 0.0006 s | **`shred:start`** | 143 | **half-reaped** — orphaned inner task lost |
| `shieldawait` | `task.cancel()`; inner shielded, **awaited by lifespan** | teardown | 0.0011 s | **`namespace:done`** | 143 | completed in 0.866 s |

Figures come from the re-run on 2026-09-23 after the Cato audit. Each run has its own log, `events-<variant>-<shutdown>-<signal>-<after>.log`. In the idle `good` run the log shows `isolated exception: RuntimeError('isolated boom on tick 3')` followed by `tick 4`, which confirms per-iteration isolation.

Exit codes: uvicorn 0.30.6 re-raises the signal it caught after restoring the original handler, so a *clean* SIGTERM shutdown exits **143**. A 143 in pod events is not evidence of a crash. † The SIGINT exit 0 is a harness artefact: uvicorn ran as a background job of a non-interactive shell, so SIGINT was inherited as `SIG_IGN`. In a foreground run it would exit 130. A *second* SIGINT sets uvicorn's `force_exit` and skips lifespan shutdown and the reaper drain entirely. The kubelet sends only SIGTERM and then SIGKILL, so this matters for local runs, not in-cluster.

### Evaluation-pass cost (real `LifecycleManager`)

| Environments | Idle pass | All-due pass (N transitions) | Idle duty cycle @ 30 s |
| ---: | ---: | ---: | ---: |
| 10 | 0.005 ms | 0.06 ms | 0.00002 % |
| 100 | 0.046 ms | 0.62 ms | 0.00015 % |
| 1,000 | 0.451 ms | 5.07 ms | 0.0015 % |
| 10,000 | 5.506 ms | 75.10 ms | 0.018 % |

The pass runs synchronously under `threading.RLock`, so it blocks the loop for its full duration. That is harmless up to about 1,000 environments. At 10,000, an all-due pass holds the loop for 75 ms, which is still below the 1 s probe budget but shows up as tail latency. Recommendation §5.4 (plan under the lock, act outside it) keeps the pass O(N) in memory and moves all I/O out of it.

---

## 4. Current-state defects the ReaperDaemon must not inherit

| ID | Defect | Evidence | Consequence |
| :-- | :--- | :--- | :--- |
| D1 | No loop | V7 | TTL/idle/max-lifetime never enforced without a manual call |
| D2 | Heartbeat revives expired leases | §1.5 probe | Expiry precision = reaper cadence; unauthenticated callers can extend (R3) |
| D3 | Heartbeat extends from `expires_at`, not `now` | L234 `rec.expires_at + timedelta(minutes=ext)` | Heartbeats *stack*: 8 × `extend_minutes=60` pushes the lease to the 8 h cap. Bounded, but probably not the intended "keep-alive" semantics — P2-1 should decide and pin it with a test |
| D4 | Domain layer raises `fastapi.HTTPException` | probe: `transition error type: fastapi.exceptions.HTTPException` | Inside a background loop, an HTTP exception type carries no HTTP meaning; the isolation handler must catch it or the domain must raise domain errors |
| D5 | State in process memory | L335 `GLOBAL_LIFECYCLE_MANAGER = LifecycleManager()` | Restart = amnesia = orphaned environments |
| D6 | Teardown is bookkeeping only | V8 | TERMINATED is asserted but nothing is deallocated |
| D7 | `threading.RLock` taken by sync methods called from async handlers | L131 | Safe today only because nothing inside the lock awaits or does I/O; the first teardown call placed under it will freeze the loop. `evaluate_reaping` calls `transition_state` while holding the lock, so it **depends on re-entrancy**. A `plan_reaping` refactor must not switch to a plain `Lock` without removing that nesting |

---

## 5. Architecture specification

### 5.1 Lifespan integration pattern

Own the task in `lifespan`, pace it with an `asyncio.Event` (never `asyncio.sleep` alone, never `time.sleep`), and shut it down by **draining**: set the stop event, then await with a bound. `task.cancel()` is the last resort after the bound expires, never the first move.

```python
# environment_lifecycle.py (P2-1 target shape)
class ReaperDaemon:
    def __init__(self, manager: LifecycleManager, *, interval_s: float = 30.0,
                 jitter_s: float = 3.0, executor: "TeardownExecutor") -> None:
        self._manager, self._interval, self._jitter = manager, interval_s, jitter_s
        self._executor = executor
        self._stop = asyncio.Event()
        self._task: asyncio.Task | None = None
        self.last_tick_monotonic: float | None = None   # exported (5.6)
        self.consecutive_failures = 0

    def start(self) -> None:
        self._task = asyncio.create_task(self._supervise(), name="sled-reaper")

    async def stop(self, drain_timeout_s: float) -> None:
        """Never raises (except a cancellation aimed at the caller itself)."""
        self._stop.set()
        t = self._task
        if t is None:
            return
        try:
            await asyncio.wait_for(asyncio.shield(t), drain_timeout_s)
        except asyncio.TimeoutError:
            t.cancel()                               # last resort
            await asyncio.gather(t, return_exceptions=True)
        except asyncio.CancelledError:
            if asyncio.current_task().cancelling():  # cancellation is aimed at *us*
                raise
            # otherwise the reaper task itself was cancelled elsewhere: nothing to drain
        except Exception:
            logger.exception("sled-reaper: task had already failed at shutdown")
```

```python
# main.py
@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db_pool()
    app.state.adapters = load_adapter_selections()
    await GLOBAL_LIFECYCLE_MANAGER.rehydrate()        # 5.5: durable state first
    reaper = ReaperDaemon(GLOBAL_LIFECYCLE_MANAGER, executor=...)
    reaper.start()
    app.state.reaper = reaper
    try:
        yield
    finally:
        try:
            await reaper.stop(drain_timeout_s=REAPER_DRAIN_TIMEOUT_S)  # before the pool closes
        finally:
            await close_db_pool()                    # runs even if stop() raises
```

Ordering rules:

- **Stop the reaper before `close_db_pool()`.** If the pool closes under an in-flight pass, the pass fails and leaves the checkpoint half-written.
- **Never install your own SIGTERM/SIGINT handler** with `loop.add_signal_handler` or `signal.signal`. uvicorn owns the signals and turns both into lifespan shutdown; the SIGINT probe confirms both take the same path. A second handler races uvicorn's handler.
- **No `BackgroundTasks` and no threads.** `BackgroundTasks` is request-scoped. A `threading.Thread` cannot be cooperatively cancelled and would not see the lifespan.

### 5.2 Cancellation semantics & the shutdown budget

An in-process drain *can* finish in-flight work on a graceful SIGTERM (`good` and `shieldawait` rows). Nothing in-process survives SIGKILL after the grace period, OOMKill, node loss, a crash, or uvicorn `force_exit`, though. Correctness has to come from **resumability**, and the time budget has to be set explicitly.

**Ordering caveat (uvicorn 0.30.6).** uvicorn drains HTTP connections *first* and runs `lifespan` shutdown *afterwards*. So the reaper's `_stop` is not set until up to `--timeout-graceful-shutdown` seconds after SIGTERM, and the reaper may begin new stages during that window. Without the flag, one long-lived connection can hold the HTTP drain open until SIGKILL, and the reaper drain never runs at all.

| Knob | Value | Why |
| :--- | :--- | :--- |
| `terminationGracePeriodSeconds` | **60** (set explicitly; today unset = 30) | budget: `preStop` (none today) + HTTP graceful 20 + reaper drain 25 + pool close/margin < 60 |
| uvicorn `--timeout-graceful-shutdown` | **20** | **required**, not optional (see ordering caveat); flag exists in 0.30.6 (`uvicorn --help`) |
| `REAPER_DRAIN_TIMEOUT_S` | **25** | ≥ the longest single *stage*; holds only if `executor.apply` is one stage or merely submits a Job (§5.5), or checks `stop` between stages |
| Stage granularity | one stage = one idempotent, checkpointed step | a cancellation between stages loses nothing; a cancellation *inside* a stage replays that stage |

Rules:

1. **Checkpoint after every stage, durably.** `teardown_stages_completed` has to be persisted (§5.5) *before* the next stage starts. The in-memory list, which is never written today, is not enough.
2. **On a new pass, resume from the last checkpoint.** An environment in DRAINING whose stage list is incomplete and whose grace period has expired resumes at the first missing stage.
3. **Stages must be idempotent.** `tailscale-eap-env.sh teardown` already claims to be (`# Reset proxy and log out Tailscale node idempotently`, L34). P3 must hold every other stage to the same bar.
4. **Do not start a stage you cannot finish.** Once `_stop` is set, finish the current stage and do not begin the next one. The §5.3 loop checks `_stop` only between *actions*. So either `executor.apply(action)` covers exactly one stage or submits a Job, or the stop event is passed into `apply` and checked between stages. P2-1 must choose one and test it.
5. **`CancelledError` is re-raised, never swallowed.** It must not fall into the `except Exception` isolation handler. On Python 3.12 `CancelledError` derives from `BaseException`, so `except Exception` is already correct. Never write `except BaseException`.

### 5.3 Exception isolation & backoff recovery

There are two layers, because the probe shows that a single unguarded raise ends the loop for good:

```python
async def _supervise(self) -> None:
    while not self._stop.is_set():
        try:
            await self._run_loop()
            return                                     # clean stop
        except asyncio.CancelledError:
            raise
        except Exception:                              # loop-level crash
            self.consecutive_failures += 1
            logger.exception("sled-reaper crashed; restarting (n=%d)", self.consecutive_failures)
            await self._sleep_or_stop(self._backoff())

async def _run_loop(self) -> None:
    while not self._stop.is_set():
        started = time.monotonic()
        try:
            plan = self._manager.plan_reaping()        # pure, under the lock, no I/O
            for action in plan:                        # per-environment isolation
                if self._stop.is_set():
                    break
                try:
                    await self._executor.apply(action) # all I/O here, outside the lock
                except Exception:
                    logger.exception("sled-reaper: action failed for %s", action.customer_hash)
                    REAPER_ACTION_FAILURES.labels(action.kind).inc()
            self.consecutive_failures = 0
        except Exception:                              # pass-level failure
            self.consecutive_failures += 1
            logger.exception("sled-reaper: pass failed")
        self.last_tick_monotonic = time.monotonic()
        delay = self._interval if self.consecutive_failures == 0 else self._backoff()
        await self._sleep_or_stop(max(0.0, delay - (time.monotonic() - started))
                                  + random.uniform(0, self._jitter))

def _backoff(self) -> float:
    # 30s, 60s, 120s, 240s, capped at 300s = GRACE_PERIOD_SECONDS
    return min(self._interval * 2 ** max(0, self.consecutive_failures - 1), 300.0)

async def _sleep_or_stop(self, seconds: float) -> None:
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(self._stop.wait(), timeout=seconds)
```

- **Per-action isolation:** one environment's failed teardown does not block the others in the same pass.
- **Per-pass isolation:** a failure in `plan_reaping` (for example a DB outage) backs off and retries instead of killing the loop.
- **Supervisor:** because every pass body is already inside `except Exception`, the supervisor only catches failures in the pacing code itself, so it is close to dead code. The real safety net is **mandatory**: a `task.add_done_callback` that logs any exception, including a `BaseException`, and lets `sled_reaper_last_tick_age_seconds` go stale (5.6). That way a dead task can never go unseen again.
- **Backoff sequence** `min(30·2^(n−1), 300)` gives 30, 60, 120, 240, 300, 300. The first failure retries at the base interval, and backoff starts from the second.
- **All-actions-failed counts as a pass failure.** As written, `consecutive_failures = 0` is reset even when every action failed. A persistently broken executor, for example one missing RBAC, would then retry every 30 s forever. P2-1 must count a pass with zero successes and at least one failure as a failure. It should also keep a per-environment `next_attempt_at` so one poisoned environment backs off on its own schedule.
- **Backoff cap = `GRACE_PERIOD_SECONDS` (300 s).** A reaper that backs off for longer than the grace period breaks the draining contract.
- **Catch `HTTPException` (D4) or, better, have the domain raise domain errors.** P2-1 should add `LifecycleTransitionError` and map it to HTTP only in the router.

### 5.4 Event-loop safety rules

| Operation | Required form | Forbidden |
| :--- | :--- | :--- |
| Waiting between passes | `asyncio.wait_for(stop.wait(), t)` | `time.sleep`, bare `asyncio.sleep` (can't be woken on stop) |
| Script invocation | `asyncio.create_subprocess_exec(argv…)` with a timeout; kill the process group on timeout | `subprocess.run` on the loop; any `shell=True` |
| Sync SDK calls (boto3, azure, a sync k8s client) | `await asyncio.to_thread(fn, …)` (pattern already used in `integrations/report_store.py`) | calling them directly in `async def` |
| Kubernetes API | async client, or `to_thread` around the sync client | sync client on the loop (explicitly out of scope per card) |
| `threading.RLock` | held for in-memory mutation only; **plan under the lock, act outside it** | holding the lock across `await` or any I/O (D7) |

### 5.5 Durable state & teardown delegation (resolves D5, D6, V9)

- **Durable lease store.** Persist `LifecycleRecord` (including `teardown_stages_completed`) in PostgreSQL. The pool already exists, and `/readyz` already gates on it. At startup, `rehydrate()` loads every non-TERMINATED record *before* the reaper starts, so a restart no longer means amnesia.
- **Orphan reconciliation.** Each pass (or every N passes) also lists cluster-side EAP artefacts: namespaces or HTTPRoutes labelled with the customer hash, and tailnet nodes. Any artefact with no live lease gets enqueued for teardown. This makes the reaper level-triggered against reality instead of edge-triggered against its own memory. It is the only design that closes the "Tailscale proxy slots or DNS records persist after termination" out-of-scope line.
- **Teardown executor ≠ API pod.** The API pod has neither the script nor its binaries, and its root filesystem is read-only. The reaper should create an idempotently named Kubernetes `Job` per environment (`sled-teardown-<hash>`), running an image that contains `tailscale-eap-env.sh`, under a narrowly scoped ServiceAccount. The reaper watches Job status and records stages. This also takes long-running teardown out of the shutdown budget in §5.2 altogether.
- **Single writer — and it does not hold during a rollout.** `--workers 1` and `replicas: 1` make the in-process loop the single writer at steady state. However, a RollingUpdate with the default `maxSurge: 25%` (rounded up to 1) briefly runs two pods, and therefore two reapers. P2-1 must take a PostgreSQL advisory lock every pass. Use `pg_try_advisory_xact_lock` inside the pass's transaction, or a dedicated connection held for the whole pass. A session-level `pg_try_advisory_lock` on a pooled asyncpg connection will leak the lock or release it on the wrong connection. The alternative, weaker because it leaves a gap, is `strategy: Recreate`/`maxSurge: 0`.

### 5.6 Cadence tuning (30 s)

- **Keep 30 s.** CPU cost is negligible (§3). The trade-off is between reaping latency (worst-case overshoot equals the interval plus jitter) and API/Job churn per pass.
- **Take correctness off the cadence:** fix D2 so that `record_heartbeat` returns 410 when `now >= expires_at`, and apply the same rule to `record_activity`. Once the lease enforces its own expiry, the interval only affects how promptly resources are freed. It no longer decides whether a lease is still valid. Idle-timeout detection is still cadence-bound, which is acceptable because its window is 30 minutes. There is also a current inconsistency: a lease expired by more than `extend_minutes` returns `extended=True` but stays expired, because extension is computed from `expires_at`. The D3 decision must settle whether to extend from `max(now, expires_at)` or reject, and pin it with a test.
- **Jitter 0–3 s** keeps passes from aligning with other 30 s periodic work, such as the Dockerfile `HEALTHCHECK --interval=30s`.
- **Measure from monotonic time** and subtract the pass duration, so a slow pass does not stretch the period.
- **Staleness signal:** export `sled_reaper_last_tick_age_seconds`. If it exceeds 3 × interval, the reaper is stalled or dead. Surface this through metrics and alerting, **not** through `/livez`: the `/livez` docstring promises it "intentionally touches no dependencies".

### 5.7 Telemetry contract for SLED-P2-2

`prometheus_client` is not a dependency, so P2-2 must add it and expose:

| Metric | Type | Labels |
| :--- | :--- | :--- |
| `sled_reaper_pass_duration_seconds` | Histogram | — |
| `sled_reaper_actions_total` | Counter | `kind` (draining/terminated/resume), `reason` |
| `sled_reaper_action_failures_total` | Counter | `kind` |
| `sled_reaper_consecutive_failures` | Gauge | — |
| `sled_reaper_last_tick_age_seconds` | Gauge (computed at scrape) | — |
| `sled_lifecycle_environments` | Gauge | `state` |
| `sled_teardown_stage_duration_seconds` | Histogram | `stage` |

---

## 6. Acceptance criteria handed to SLED-P2-1 / P2-2

Each criterion is one binary probe.

1. `rg -n 'create_task\(.*reaper' src/main.py src/environment_lifecycle.py` matches, and the task is started inside `lifespan`.
2. A test starts the app with `TestClient` as a context manager, waits more than one interval (with the interval injected at 0.05 s), and asserts that an expired environment is now DRAINING without anyone calling `/reap-now`.
3. A test injects an exception into `plan_reaping` on the first pass only and asserts that the reaper completes a later pass (isolation plus recovery).
4. A test asserts the backoff sequence `30, 60, 120, 240, 300, 300`.
5. A test shuts down during a stubbed multi-stage teardown and asserts that the checkpoint holds exactly the completed stages; a restarted manager then resumes at the first missing stage.
6. `rg -n 'time\.sleep|subprocess\.run|subprocess\.Popen' src/environment_lifecycle.py` returns no match (anti-criterion).
7. Heartbeat on an expired lease returns HTTP 410, as a regression test for D2.
8. `rg -n 'terminationGracePeriodSeconds: 60' base/deployment.yaml` matches, and the Dockerfile CMD carries `--timeout-graceful-shutdown`.
9. `curl /metrics` exposes every metric in §5.7 (P2-2).
10. Anti-criterion: no `add_signal_handler` and no `signal.signal(` in `environment_lifecycle.py`.
11. Anti-criterion: the reaper never holds `self._lock` across an `await`. Check with `rg` for `await` inside any `with self._lock` block.
12. A test kills the reaper task with an injected `BaseException` and asserts that the done-callback logs it and that `sled_reaper_last_tick_age_seconds` exceeds 3 × interval.
13. A test in which every action fails asserts that the next pass delay follows the backoff sequence, not the base interval.
14. A test calls `ReaperDaemon.stop()` on a task that already failed and asserts that it does not raise and that `close_db_pool` is still awaited.
15. The pass acquires `pg_try_advisory_xact_lock` (probe: `rg`), and a two-manager test shows that only one pass runs at a time.

---

## 7. Risks outside P2 scope, surfaced for the board

| ID | Risk | Owner |
| :-- | :--- | :--- |
| R1 | Teardown needs an executor image and RBAC that do not exist yet (§5.5) | SLED-P3-PRE / P3-1 |
| R2 | Orphans created before durable state lands can only be recovered through cluster-side reconciliation | SLED-P2-1 |
| R3 | `/api/v1/eap/lifecycle/*` is unauthenticated (V12). Any caller can register environments, keep any lease alive up to the 8 h cap (combined with D2/D3, a cost-exposure vector), or trigger a reaping pass. | SLED board governor — needs an auth dependency like `enforce_strict_operator_tenant` used in `api_compat.py:7167` |
| R4 | Heartbeat stacking semantics (D3) need an explicit product decision | SLED-P2-1 |

---

## 8. Reproduction

The probe harness lives outside the repo (`/tmp/sled-p2-probe/`). The essentials follow so the results can be re-run.

- `app.py`: a FastAPI app whose `lifespan` creates a `reaper(stop)` task. `VARIANT` selects one of:
  - `good`: Event-paced, per-iteration `except Exception`, shielded teardown.
  - `blocking`: `time.sleep(2)` in the loop.
  - `naked`: raises on tick 3 outside any try.
  - `unshielded`, `shieldcancel`, `shieldawait`: teardown on tick 2, four 0.4 s stages. The inner teardown logs its own cancellation. `shieldawait` keeps a reference to the inner task and lifespan awaits it.

  `SHUTDOWN=cancel` makes `lifespan` call `task.cancel()` before awaiting. `drain` sets the event and awaits with `wait_for(shield(task), 5)`.
- `drive.sh <variant> <drain|cancel> <signal_after_s> <port>` (with `SIG=INT` to send SIGINT): starts uvicorn, samples `/livez` latency six times, reads `/reaper`, sends the signal, and prints `events-<variant>-<shutdown>-<signal>-<after>.log`. Each run writes a unique log.

```bash
export UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache
R="uv run -q --python 3.12 --with fastapi==0.115.6 --with uvicorn[standard]==0.30.6 --with httpx bash"
$R drive.sh good drain 1.2 18706          # completes all stages
$R drive.sh shieldcancel cancel 1.2 18705 # stops at shred:start (inner not awaited)
$R drive.sh shieldawait cancel 1.2 18717  # completes (inner awaited)
$R drive.sh naked drain 3.0 18702         # task dead, /livez healthy
$R drive.sh blocking drain 2.0 18703      # /livez ~2s
```

The lifecycle suite, from `d2-signalloom/apps/fe-signalloom/src`:

```bash
UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache uv run --python 3.12 --with pytest \
  --with pytest-asyncio --with-requirements requirements.txt \
  python -m pytest tests/test_environment_lifecycle.py -v      # 8 passed
```

---

## Errata — SLED-P2-PRE

- **SLED-P2-PRE** (2026-09-23, kanban `bb360`, base `integration/sled-v0.1.0@3b73e570`): **Status: pass.** The preflight audit is complete and evidenced; implementation gaps are handed to P2-1 and P2-2 (§6).
  - This entry supersedes the pre-seeded `Initial errata record. Status: pass. Async background task concurrency safety verified.` in `docs/Proposal — Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (2026-Q3).md`, which carried no evidence. The card cites a "Spec: Errata RESET block" in that proposal; **no such block is present on disk** (`rg -n RESET` → no match; file mtime 2026-09-17).
  - Prior-work verification table: §2 (V1–V14).
  - Empirical evidence: §3. Shutdown contract: §5.2. Isolation and backoff: §5.3. Acceptance criteria for P2-1/P2-2: §6.
  - **Pending mirror:** this block could not be written into the proposal file itself. That file lives in the primary checkout, outside this worktree, and the write was refused by the agent sandbox (EACCES on the temp file, although the directory is Unix-writable). It needs copying into the proposal's `### Spec: Errata` section, replacing the pre-seeded P2-PRE line.
  - Cross-vendor audit (Cato, GPT-5.4): verdict `concerns`, 0 critical. All factual code claims were confirmed. Three major findings were corrected in this revision: (1) the shield probe was confounded, so a `shieldawait` variant was added and the finding restated; (2) `stop()` could raise and skip `close_db_pool()`, now hardened; (3) the drain budget assumed per-stage `_stop` checks and ignored uvicorn's HTTP-first shutdown ordering. All probes were re-run with unique per-run logs.
