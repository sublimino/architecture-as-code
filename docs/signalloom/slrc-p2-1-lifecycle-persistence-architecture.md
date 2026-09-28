# Environment Lifecycle Persistence & Concurrency Safety Architecture

> **Card:** SLRC-P2-1 · **Component:** `d2-signalloom/apps/fe-signalloom`
> **Status:** Implemented and verified with comprehensive unit and API regression suite
> **Contracts:** [`environment_lifecycle.py`](../../d2-signalloom/apps/fe-signalloom/src/environment_lifecycle.py), [`environment_lifecycle_store.py`](../../d2-signalloom/apps/fe-signalloom/src/environment_lifecycle_store.py)
> **Migration:** [`044_eap_lifecycle_fencing.sql`](../../d2-signalloom/apps/fe-signalloom/src/db/migrations/044_eap_lifecycle_fencing.sql)

## Overview

The Signal Loom Environment Lifecycle subsystem provides durable state transition governance, ordered teardown checkpointing, and exclusive background worker claims for ephemeral customer environments (EAP).

This architecture prevents race conditions, lease expiration split-brain scenarios, zombie worker executions, and illegal lifecycle state progressions across concurrent distributed worker processes.

## State Transition Matrix

The lifecycle state machine enforces strict predecessor prerequisites and terminal transition gates:

```
[PROVISIONING] ───────┬──────> [WARMING] ──────> [ACTIVE] ──────> [DRAINING]
      │               │                            │                 │
      │               └────────────────────────────┘                 │
      ▼                                                              ▼
 [DRAINING] <────────────────────────────────────────────────────────┘
      │
      ▼ (Background Reaping & 4-Stage Ordered Checkpoints)
 [TEARDOWN_FAILED] <─── (Failure / Retry)
      │
      ▼ (All 4 Checkpoints Durably Completed)
 [TERMINATED] (Terminal Gate)
```

| Source State | Permitted Destination States | Transition Gate & Prerequisites |
| :--- | :--- | :--- |
| `PROVISIONING` | `WARMING`, `ACTIVE`, `DRAINING` | Public API / operator transition |
| `WARMING` | `ACTIVE`, `DRAINING` | Public API / operator transition |
| `ACTIVE` | `DRAINING` | Public API / TTL expiry / max lifetime / idle timeout |
| `DRAINING` | None directly | Handled exclusively via reaper background reconciliation |
| `TEARDOWN_FAILED` | None directly | Handled exclusively via reaper retry reconciliation |
| `TERMINATED` | None (Terminal) | **Hard Gate**: Only settable by `complete_claim()` after all 4 stages (`route`, `mesh`, `key_spire`, `namespace_storage`) are verified complete |

Attempting an unlisted state transition raises `HTTPException(400)`. Attempting to set `TERMINATED` via `transition_state()` directly raises `InvalidStateTransitionError("TERMINATED requires durable teardown completion")`.

## Concurrency and Mutual Exclusion Model

### 1. Row-Level Atomic Locking & Worker Lease Claims
When worker tasks search for pending teardown tasks (`draining` past grace period or `teardown_failed` past retry backoff):
- PostgreSQL implementation uses row-level locking:
  ```sql
  WITH candidate AS (
    SELECT customer_hash, claim_owner AS previous_claim_owner
    FROM public.eap_environment_lifecycle
    WHERE ((state='draining' AND grace_period_expires_at <= $1)
        OR (state='teardown_failed' AND next_retry_at <= $1))
      AND (claim_owner IS NULL OR claim_expires_at <= $1)
    ORDER BY COALESCE(next_retry_at, grace_period_expires_at), customer_hash
    FOR UPDATE SKIP LOCKED LIMIT 1
  )
  UPDATE public.eap_environment_lifecycle AS lifecycle SET
    claim_owner=$2, claim_expires_at=$3,
    teardown_id=COALESCE(lifecycle.teardown_id, $4),
    claim_fencing_token=lifecycle.claim_fencing_token + 1,
    version=lifecycle.version + 1, updated_at=NOW()
  FROM candidate WHERE lifecycle.customer_hash=candidate.customer_hash
  RETURNING lifecycle.*, candidate.previous_claim_owner;
  ```
- Exactly one worker claims each record even under high concurrency.
- `SKIP LOCKED` ensures competing workers do not block or deadlock; they immediately evaluate subsequent records.

### 2. Monotonic Claim Fencing Token
- Every claim acquisition and takeover increments `claim_fencing_token` monotonically.
- All subsequent mutation operations (`checkpoint_stage`, `fail_claim`, `complete_claim`) assert that `claim_fencing_token` matches the worker's active lease token.
- If a worker's lease expires and another worker takes over the claim, any delayed mutation from the previous worker is rejected with `ValueError("stale fencing token ...")`.

### 3. Transactional Outbox Consistency
- Terminal transitions, checkpoint progressions, and failure events are committed inside the **exact same database transaction** as the lifecycle state update.
- When an expired claim is taken over by a new worker, an outbox audit record (`event_type="eap.teardown.claim_taken_over"`) is generated and atomically committed with the claim update.
- Prevents outbox event duplication or orphaned state changes on system crashes.

### 4. Fail-Closed Stage Executor Verification & Hard Timeout
- `_execute_teardown_claim` verifies that the configured `StageExecutor` implements a valid `verify(stage, request)` method before attempting execution. If verification is absent or fails, the claim immediately transitions to `teardown_failed` with `reason="verification_unavailable"`.
- Stage execution is guarded by a hard deadline (`stage_timeout_seconds` with `asyncio.wait_for`). If an adapter provider hangs, the execution is terminated and recorded as `teardown_failed` with `reason="stage_timeout"`.

### 5. Optimistic Concurrency and Conflict Isolation
- Heartbeat and activity updates (`record_heartbeat`, `record_activity`) catch optimistic concurrency conflicts (`ValueError("lifecycle record changed concurrently")`) and retry once against fresh state. If conflict persists, they surface `HTTP 409 Conflict` rather than an unhandled 500 error.
- Reaping reconciliation (`evaluate_reaping`) isolates failures per row: a concurrent conflict on one environment is logged and skipped, ensuring later rows continue processing without starvation.

### 6. API Route Governance and Superadmin Authorization
- Mutating administrative routes (`POST /api/v1/eap/lifecycle/register` and `POST /api/v1/eap/lifecycle/reap-now`) require validated `Principal` identity and enforce server-side `require_superadmin` checks (returning 401 for unauthenticated requests, 403 for non-superadmin callers).
- Public observation routes (`GET /api/v1/eap/lifecycle/active` and `GET /api/v1/eap/lifecycle/environments/{customer_hash}`) remain open for monitoring.
