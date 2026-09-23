# SLED-P2-1: Asynchronous ReaperDaemon Background Reconciliation Loop

## 1. Overview & Architectural Role

The **Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (SLED)** guarantees deterministic, bounded lifecycles for on-demand customer evaluation environments. The **ReaperDaemon** (`d2-signalloom/apps/fe-signalloom/src/environment_lifecycle.py`) is the authoritative background reconciliation loop responsible for continuously evaluating active and draining environments, detecting lease expirations and idle timeouts, and advancing states through the formal lifecycle graph:

```
[PROVISIONING / WARMING / ACTIVE]
          │
          │ (TTL Expired / Max Lifetime Exceeded / 30m Idle Timeout)
          ▼
      [DRAINING]  (300s Grace Period)
          │
          │ (Grace Period Expired)
          ▼
    [TERMINATED] ──> (Teardown & Key Shredding Triggered)
```

---

## 2. Core Components

### 2.1 Asynchronous Background Worker (`ReaperDaemon`)
- **Event-Loop Native**: Runs as an `asyncio.Task` managed directly by the FastAPI `lifespan` context in `main.py`.
- **Graceful Lifecycle Integration**:
  - **Startup**: `GLOBAL_REAPER_DAEMON.start()` spawns the background loop asynchronously on application initialization.
  - **Shutdown**: `await GLOBAL_REAPER_DAEMON.stop(timeout=5.0)` cancels the running loop, drains any active reconciliation pass, and ensures zero orphaned tasks or leaked threads.
- **Mutual Exclusion & Re-entrancy**: Backed by `threading.RLock` with bounded lock acquisition timeouts (`LOCK_TIMEOUT_SECONDS = 5.0`), preventing deadlocks and lock contention during concurrent API traffic.

### 2.2 Reaping Evaluation Algorithm (`evaluate_reaping`)
The evaluation scan executes with sub-millisecond latency and deterministic ordering:
1. **Dynamic Priority Queue Sorting**:
   - **Priority 0 (Urgent Expiration)**: Environments with expired TTL (`current_time >= expires_at`) or exceeded unextendable ceiling (`current_time >= max_lifetime_expires_at`).
   - **Priority 1 (Draining Eviction)**: Environments in `DRAINING` state past grace period expiration (`current_time >= grace_period_expires_at`).
   - **Priority 2 (Inactivity Expiration)**: Environments exceeding the 30-minute idle threshold (`current_time >= last_activity_at + 30m`).
   - **Priority 3 (Nominal)**: Healthy active environments.
2. **State Transition Rules**:
   - Active environments transitioning to `DRAINING` compute `grace_period_expires_at = now + 300s` and record `reap_reason` (`ttl_expired`, `max_lifetime_exceeded`, `idle_timeout`).
   - Draining environments transitioning to `TERMINATED` record `grace_period_expired`.
3. **Nanosecond-Precision Timestamps**: All transitions capture `transition_timestamp_ns = time.time_ns()` for high-resolution distributed trace correlation.

### 2.3 Adaptive Polling Interval Scheduler (`AdaptiveIntervalScheduler`)
To optimize CPU and event-loop overhead:
- **Nominal Base Interval**: 30.0 seconds (`DEFAULT_REAPER_INTERVAL_SECONDS`).
- **Idle Fleet Backoff**: When the fleet has 0 active environments and 0 transitions across consecutive reconciliation passes, the scheduler applies exponential backoff:
  $$\text{interval} = \min(120.0, 30.0 \times 1.5^{\min(\text{empty\_cycles}, 4)})$$
- **Instant Reset**: As soon as any environment becomes active or a registration occurs, the interval immediately resets to 30.0s.

### 2.4 Exception Isolation & Dead-Letter Queue (`DeadLetterQueue`)
- **Per-Environment Fault Isolation**: An unexpected exception when transitioning one environment is captured and logged without interrupting evaluation of sibling environments.
- **Three-Cycle Circuit Breaker**: If an environment encounters exceptions across 3 consecutive reconciliation passes (`MAX_RECONCILIATION_FAILURES`), it is automatically routed to the `DeadLetterQueue` (`ERR_TRANSITION_FAILED`) and dispatches an alert.

### 2.5 Memory Watchdog (`MemoryWatchdog`)
- Continuously inspects Resident Set Size (RSS) memory consumption via `resource.getrusage` / `/proc/self/statm`.
- Asserts that worker RSS footprint remains bounded below 50 MB (`MAX_RSS_BYTES = 50 * 1024 * 1024`).

### 2.6 Administrative Controls (`pause` / `resume`)
- Operators can suspend background reconciliation during cluster maintenance:
  - `POST /api/v1/eap/lifecycle/reaper/pause`
  - `POST /api/v1/eap/lifecycle/reaper/resume`
  - `GET /api/v1/eap/lifecycle/reaper/status`

---

## 3. Structured Audit Log & Telemetry Schema

Every transition emits a structured audit record adhering to the unified Signal Loom audit schema:

```json
{
  "event_id": "8f03c41a-82dc-4a6f-9988-1d2f782ad81b",
  "timestamp": "2026-09-23T02:50:00.000000+00:00",
  "timestamp_ns": 1790131800000000000,
  "customer_hash": "6f82ad81",
  "company_name": "kurasi",
  "previous_state": "active",
  "current_state": "draining",
  "trigger_reason": "ttl_expired",
  "operator_or_system_id": "system:reaper-daemon",
  "metadata": {}
}
```

Prometheus telemetry metrics exported:
- `signalloom_eap_reaper_cycles_total`: Total completed background reconciliation passes.
- `signalloom_eap_active_environments`: Gauge of non-terminated managed environments.
- `signalloom_eap_reaped_total`: Counter of state transitions partitioned by action and reason.
- `signalloom_eap_reaper_duration_seconds`: Histogram/duration of evaluation passes.
- `signalloom_eap_dlq_total`: Gauge of records currently held in Dead-Letter Queue.

---

## 4. API Surface

| Endpoint | Method | Description |
|---|---|---|
| `/api/v1/eap/lifecycle/register` | `POST` | Register environment with lease window (default 120m, max 480m) |
| `/api/v1/eap/lifecycle/environments/{hash}/heartbeat` | `POST` | Extend lease up to hard 8-hour ceiling |
| `/api/v1/eap/lifecycle/environments/{hash}/activity` | `POST` | Reset 30-minute idle activity timer |
| `/api/v1/eap/lifecycle/environments/{hash}` | `GET` | Query detailed lifecycle state record |
| `/api/v1/eap/lifecycle/active` | `GET` | List active environments |
| `/api/v1/eap/lifecycle/reap-now` | `POST` | Manually trigger authoritative reconciliation pass |
| `/api/v1/eap/lifecycle/reaper/pause` | `POST` | Administratively suspend background loop |
| `/api/v1/eap/lifecycle/reaper/resume` | `POST` | Administratively resume background loop |
| `/api/v1/eap/lifecycle/reaper/status` | `GET` | Retrieve daemon health, interval, and memory metrics |
| `/api/v1/eap/lifecycle/reaper/dlq` | `GET` | Retrieve dead-letter queue records |
| `/api/v1/eap/lifecycle/reaper/dlq/clear` | `POST` | Clear dead-letter queue records |
| `/api/v1/eap/lifecycle/audit-events` | `GET` | Retrieve immutable transition audit events |
| `/api/v1/eap/lifecycle/metrics` | `GET` | Retrieve Prometheus lifecycle telemetry |
