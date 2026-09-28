"""Durable persistence boundary for EAP lifecycle and teardown coordination."""
from __future__ import annotations

import asyncio
import json
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Protocol

from environment_teardown_contract import ORDERED_STAGES


@dataclass(frozen=True)
class LifecycleRow:
    customer_hash: str
    company_name: str
    state: str
    created_at: datetime
    last_heartbeat_at: datetime
    last_activity_at: datetime
    expires_at: datetime
    max_lifetime_expires_at: datetime
    grace_period_expires_at: datetime | None = None
    reap_reason: str | None = None
    teardown_id: str | None = None
    teardown_stages_completed: list[str] = field(default_factory=list)
    retry_count: int = 0
    next_retry_at: datetime | None = None
    last_error: str | None = None
    claim_owner: str | None = None
    claim_expires_at: datetime | None = None
    version: int = 1
    claim_fencing_token: int = 0


class LifecycleStore(Protocol):
    async def create(self, row: LifecycleRow, event: dict[str, Any]) -> LifecycleRow: ...
    async def get(self, customer_hash: str) -> LifecycleRow | None: ...
    async def list_active(self) -> list[LifecycleRow]: ...
    async def replace(self, row: LifecycleRow, expected_version: int, event: dict[str, Any]) -> LifecycleRow: ...
    async def claim_due(self, worker_id: str, now: datetime, lease: timedelta) -> LifecycleRow | None: ...
    async def checkpoint_stage(self, customer_hash: str, worker_id: str, teardown_id: str,
                               *args: Any, **kwargs: Any) -> LifecycleRow: ...
    async def fail_claim(self, customer_hash: str, worker_id: str, teardown_id: str,
                         *args: Any, **kwargs: Any) -> LifecycleRow: ...
    async def complete_claim(self, customer_hash: str, worker_id: str, teardown_id: str,
                             *args: Any, **kwargs: Any) -> LifecycleRow: ...


def _validate_checkpoint(
    row: LifecycleRow | None,
    worker_id: str,
    teardown_id: str,
    stage: str | None,
    expected_completed: tuple[str, ...],
    fencing_token: int | None = None,
    now: datetime | None = None,
) -> bool:
    if row is None:
        raise ValueError("lifecycle record not found")
    if now is not None and row.claim_expires_at is not None and now > row.claim_expires_at:
        raise ValueError(f"claim expired for {row.customer_hash}")
    if fencing_token is not None and row.claim_fencing_token != fencing_token:
        raise ValueError(f"stale fencing token {fencing_token}, current is {row.claim_fencing_token}")
    if row.claim_owner != worker_id or row.teardown_id != teardown_id:
        raise ValueError("claim owner or teardown id does not match")
    if stage is not None:
        completed = tuple(row.teardown_stages_completed)
        if stage in completed:
            return False
        if completed != expected_completed:
            raise ValueError("ordered checkpoint prefix changed")
        ordered = tuple(item.value for item in ORDERED_STAGES)
        if len(completed) >= len(ordered) or ordered[len(completed)] != stage:
            raise ValueError("ordered checkpoint violation")
    return True


def _parse_checkpoint_args(
    arg4: Any, arg5: Any = None, arg6: Any = None, arg7: Any = None
) -> tuple[int | None, str, tuple[str, ...], dict[str, Any]]:
    if isinstance(arg4, int):
        fencing_token = arg4
        stage = str(arg5)
        expected_completed = tuple(arg6) if arg6 is not None else ()
        event = dict(arg7) if arg7 else {}
        return fencing_token, stage, expected_completed, event
    else:
        fencing_token = None
        stage = str(arg4)
        expected_completed = tuple(arg5) if arg5 is not None else ()
        event = dict(arg6) if arg6 else {}
        return fencing_token, stage, expected_completed, event


def _parse_fail_args(
    arg4: Any, arg5: Any = None, arg6: Any = None, arg7: Any = None
) -> tuple[int | None, str, datetime, dict[str, Any]]:
    if isinstance(arg4, int):
        fencing_token = arg4
        error = str(arg5)
        next_retry_at = arg6
        event = dict(arg7) if arg7 else {}
        return fencing_token, error, next_retry_at, event
    else:
        fencing_token = None
        error = str(arg4)
        next_retry_at = arg5
        event = dict(arg6) if arg6 else {}
        return fencing_token, error, next_retry_at, event


def _parse_complete_args(
    arg4: Any, arg5: Any = None, arg6: Any = None
) -> tuple[int | None, tuple[str, ...], dict[str, Any]]:
    if isinstance(arg4, int):
        fencing_token = arg4
        required_stages = tuple(arg5) if arg5 is not None else ()
        event = dict(arg6) if arg6 else {}
        return fencing_token, required_stages, event
    else:
        fencing_token = None
        required_stages = tuple(arg4) if arg4 is not None else ()
        event = dict(arg5) if arg5 else {}
        return fencing_token, required_stages, event


class InMemoryLifecycleStore:
    """Deterministic test store; production wiring never selects this class."""

    def __init__(self, clock: Callable[[], datetime] | None = None) -> None:
        self._rows: dict[str, LifecycleRow] = {}
        self._lock = asyncio.Lock()
        self.outbox: list[dict[str, Any]] = []
        self._clock = clock
        self._current_time: datetime | None = None

    def _now(self, now: datetime | None = None) -> datetime:
        if now is not None:
            self._current_time = now
            return now
        if self._clock is not None:
            return self._clock()
        if self._current_time is not None:
            return self._current_time
        return datetime.now(timezone.utc)

    def _event(self, event: dict[str, Any]) -> None:
        if event:
            self.outbox.append(dict(event))

    async def create(self, row: LifecycleRow, event: dict[str, Any]) -> LifecycleRow:
        async with self._lock:
            existing = self._rows.get(row.customer_hash.lower())
            if existing is not None and existing.state != "terminated":
                return existing
            self._rows[row.customer_hash.lower()] = row
            self._event(event)
            return row

    async def get(self, customer_hash: str) -> LifecycleRow | None:
        async with self._lock:
            return self._rows.get(customer_hash.lower())

    async def list_active(self) -> list[LifecycleRow]:
        async with self._lock:
            return [row for row in self._rows.values() if row.state != "terminated"]

    async def replace(self, row: LifecycleRow, expected_version: int, event: dict[str, Any]) -> LifecycleRow:
        async with self._lock:
            current = self._rows.get(row.customer_hash.lower())
            if current is None or current.version != expected_version:
                raise ValueError("lifecycle record changed concurrently")
            updated = replace(row, version=expected_version + 1)
            self._rows[row.customer_hash.lower()] = updated
            self._event(event)
            return updated

    async def claim_due(self, worker_id: str, now: datetime, lease: timedelta) -> LifecycleRow | None:
        async with self._lock:
            effective_now = self._now(now)
            candidates: list[LifecycleRow] = []
            for row in self._rows.values():
                if row.state not in {"draining", "teardown_failed"}:
                    continue
                if (
                    row.state == "draining"
                    and row.grace_period_expires_at is not None
                    and row.grace_period_expires_at > effective_now
                ):
                    continue
                if (
                    row.state == "teardown_failed"
                    and row.next_retry_at is not None
                    and row.next_retry_at > effective_now
                ):
                    continue
                if row.claim_owner is not None and (
                    row.claim_expires_at is None or row.claim_expires_at > effective_now
                ):
                    continue
                candidates.append(row)

            if not candidates:
                return None

            candidates.sort(
                key=lambda r: (
                    r.next_retry_at or r.grace_period_expires_at or r.created_at,
                    r.customer_hash,
                )
            )
            candidate = candidates[0]

            is_takeover = candidate.claim_owner is not None and candidate.claim_owner != worker_id
            new_fencing_token = candidate.claim_fencing_token + 1
            new_teardown_id = candidate.teardown_id or str(uuid.uuid4())

            updated = replace(
                candidate,
                claim_owner=worker_id,
                claim_expires_at=effective_now + lease,
                teardown_id=new_teardown_id,
                claim_fencing_token=new_fencing_token,
                version=candidate.version + 1,
            )
            self._rows[candidate.customer_hash.lower()] = updated

            if is_takeover:
                self._event({
                    "event_id": str(uuid.uuid4()),
                    "event_type": "eap.teardown.claim_taken_over",
                    "timestamp": effective_now,
                    "customer_hash": candidate.customer_hash,
                    "company_name": candidate.company_name,
                    "previous_claim_owner": candidate.claim_owner,
                    "claim_owner": worker_id,
                    "operator_or_system_id": worker_id,
                    "claim_fencing_token": new_fencing_token,
                    "teardown_id": new_teardown_id,
                    "previous_state": candidate.state,
                    "current_state": candidate.state,
                    "trigger_reason": "lease_expired_takeover",
                })
            return updated

    async def checkpoint_stage(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        arg4: Any, arg5: Any = None, arg6: Any = None, arg7: Any = None,
        **kwargs: Any,
    ) -> LifecycleRow:
        fencing_token, stage, expected_completed, event = _parse_checkpoint_args(arg4, arg5, arg6, arg7)
        if "expected_completed" in kwargs:
            expected_completed = tuple(kwargs["expected_completed"])
        if "event" in kwargs:
            event = dict(kwargs["event"])
        async with self._lock:
            row = self._rows.get(customer_hash.lower())
            now = self._now()
            valid = _validate_checkpoint(
                row, worker_id, teardown_id, stage, expected_completed,
                fencing_token=fencing_token, now=now,
            )
            if not valid:
                assert row is not None
                return row
            assert row is not None
            updated = replace(
                row,
                teardown_stages_completed=row.teardown_stages_completed + [stage],
                version=row.version + 1,
            )
            self._rows[customer_hash.lower()] = updated
            self._event(event)
            return updated

    async def fail_claim(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        arg4: Any, arg5: Any = None, arg6: Any = None, arg7: Any = None,
        **kwargs: Any,
    ) -> LifecycleRow:
        fencing_token, error, next_retry_at, event = _parse_fail_args(arg4, arg5, arg6, arg7)
        if "event" in kwargs:
            event = dict(kwargs["event"])
        async with self._lock:
            row = self._rows.get(customer_hash.lower())
            now = self._now()
            _validate_checkpoint(
                row, worker_id, teardown_id, None, (),
                fencing_token=fencing_token, now=now,
            )
            assert row is not None
            updated = replace(
                row,
                state="teardown_failed",
                retry_count=row.retry_count + 1,
                next_retry_at=next_retry_at,
                last_error=error,
                claim_owner=None,
                claim_expires_at=None,
                version=row.version + 1,
            )
            self._rows[customer_hash.lower()] = updated
            self._event(event)
            return updated

    async def complete_claim(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        arg4: Any, arg5: Any = None, arg6: Any = None,
        **kwargs: Any,
    ) -> LifecycleRow:
        fencing_token, required_stages, event = _parse_complete_args(arg4, arg5, arg6)
        if "event" in kwargs:
            event = dict(kwargs["event"])
        async with self._lock:
            row = self._rows.get(customer_hash.lower())
            now = self._now()
            _validate_checkpoint(
                row, worker_id, teardown_id, None, (),
                fencing_token=fencing_token, now=now,
            )
            assert row is not None
            if tuple(row.teardown_stages_completed) != required_stages:
                raise ValueError("all teardown stages must be durably complete")
            updated = replace(
                row,
                state="terminated",
                next_retry_at=None,
                last_error=None,
                claim_owner=None,
                claim_expires_at=None,
                version=row.version + 1,
            )
            self._rows[customer_hash.lower()] = updated
            self._event(event)
            return updated


@asynccontextmanager
async def _connection(source: Any):
    acquire = getattr(source, "acquire", None)
    if acquire is None:
        yield source
    else:
        async with acquire() as connection:
            yield connection


class PostgresLifecycleStore:
    """Asyncpg-backed store with transactional state and outbox updates."""

    def __init__(self, pool_or_connection: Any) -> None:
        self._source = pool_or_connection

    @staticmethod
    def _row(record: Any) -> LifecycleRow | None:
        if record is None:
            return None
        return LifecycleRow(**{field: record[field] for field in LifecycleRow.__dataclass_fields__})

    @staticmethod
    async def _outbox(connection: Any, event: dict[str, Any]) -> None:
        if not event:
            return
        await connection.execute(
            """INSERT INTO public.eap_lifecycle_outbox
                   (event_id, customer_hash, event_type, occurred_at, payload)
                 VALUES ($1::uuid, $2, $3, $4, $5::jsonb)""",
            uuid.UUID(event.get("event_id", str(uuid.uuid4()))), event["customer_hash"],
            event.get("event_type", "eap.lifecycle.transition"),
            event.get("timestamp", datetime.now(timezone.utc)),
            json.dumps(event, default=str),
        )

    async def create(self, row: LifecycleRow, event: dict[str, Any]) -> LifecycleRow:
        async with _connection(self._source) as connection, connection.transaction():
            record = await connection.fetchrow(
                """INSERT INTO public.eap_environment_lifecycle
                   (customer_hash, company_name, state, created_at, last_heartbeat_at,
                    last_activity_at, expires_at, max_lifetime_expires_at,
                    grace_period_expires_at, reap_reason, claim_fencing_token)
                   VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
                   ON CONFLICT (customer_hash) DO UPDATE SET
                     company_name=EXCLUDED.company_name,
                     state=EXCLUDED.state,
                     created_at=EXCLUDED.created_at,
                     last_heartbeat_at=EXCLUDED.last_heartbeat_at,
                     last_activity_at=EXCLUDED.last_activity_at,
                     expires_at=EXCLUDED.expires_at,
                     max_lifetime_expires_at=EXCLUDED.max_lifetime_expires_at,
                     grace_period_expires_at=NULL, reap_reason=NULL, teardown_id=NULL,
                     teardown_stages_completed='{}', retry_count=0, next_retry_at=NULL,
                     last_error=NULL, claim_owner=NULL, claim_expires_at=NULL,
                     version=eap_environment_lifecycle.version+1, updated_at=NOW()
                   WHERE eap_environment_lifecycle.state='terminated'
                   RETURNING *""",
                row.customer_hash.lower(), row.company_name, row.state, row.created_at,
                row.last_heartbeat_at, row.last_activity_at, row.expires_at,
                row.max_lifetime_expires_at, row.grace_period_expires_at, row.reap_reason,
                row.claim_fencing_token,
            )
            if record is None:
                record = await connection.fetchrow(
                    "SELECT * FROM public.eap_environment_lifecycle WHERE customer_hash=$1", row.customer_hash.lower()
                )
            else:
                await self._outbox(connection, event)
            return self._row(record)  # type: ignore

    async def get(self, customer_hash: str) -> LifecycleRow | None:
        async with _connection(self._source) as connection:
            return self._row(await connection.fetchrow(
                "SELECT * FROM public.eap_environment_lifecycle WHERE customer_hash=$1", customer_hash.lower()
            ))

    async def list_active(self) -> list[LifecycleRow]:
        async with _connection(self._source) as connection:
            records = await connection.fetch(
                "SELECT * FROM public.eap_environment_lifecycle WHERE state <> 'terminated' ORDER BY customer_hash"
            )
            return [self._row(record) for record in records if record is not None]  # type: ignore

    async def replace(self, row: LifecycleRow, expected_version: int, event: dict[str, Any]) -> LifecycleRow:
        async with _connection(self._source) as connection, connection.transaction():
            record = await connection.fetchrow(
                """UPDATE public.eap_environment_lifecycle SET
                   company_name=$2, state=$3, created_at=$4, last_heartbeat_at=$5,
                   last_activity_at=$6, expires_at=$7, max_lifetime_expires_at=$8,
                   grace_period_expires_at=$9, reap_reason=$10,
                   teardown_stages_completed=$11::text[], retry_count=$12,
                   next_retry_at=$13, last_error=$14, version=version+1, updated_at=NOW()
                   WHERE customer_hash=$1 AND version=$15 RETURNING *""",
                row.customer_hash.lower(), row.company_name, row.state, row.created_at,
                row.last_heartbeat_at, row.last_activity_at, row.expires_at,
                row.max_lifetime_expires_at, row.grace_period_expires_at, row.reap_reason,
                row.teardown_stages_completed, row.retry_count, row.next_retry_at,
                row.last_error, expected_version,
            )
            if record is None:
                raise ValueError("lifecycle record changed concurrently")
            await self._outbox(connection, event)
            return self._row(record)  # type: ignore

    async def claim_due(self, worker_id: str, now: datetime, lease: timedelta) -> LifecycleRow | None:
        teardown_id = str(uuid.uuid4())
        async with _connection(self._source) as connection, connection.transaction():
            record = await connection.fetchrow(
                """WITH candidate AS (
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
                   RETURNING lifecycle.*, candidate.previous_claim_owner""",
                now, worker_id, now + lease, teardown_id,
            )
            if record is None:
                return None
            prev_owner = record.get("previous_claim_owner")
            row_res = self._row(record)
            assert row_res is not None
            if prev_owner is not None and prev_owner != worker_id:
                takeover_event = {
                    "event_id": str(uuid.uuid4()),
                    "event_type": "eap.teardown.claim_taken_over",
                    "timestamp": now,
                    "customer_hash": row_res.customer_hash,
                    "company_name": row_res.company_name,
                    "previous_claim_owner": prev_owner,
                    "claim_owner": worker_id,
                    "operator_or_system_id": worker_id,
                    "claim_fencing_token": row_res.claim_fencing_token,
                    "teardown_id": row_res.teardown_id,
                    "previous_state": row_res.state,
                    "current_state": row_res.state,
                    "trigger_reason": "lease_expired_takeover",
                }
                await self._outbox(connection, takeover_event)
            return row_res

    async def checkpoint_stage(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        arg4: Any, arg5: Any = None, arg6: Any = None, arg7: Any = None,
        **kwargs: Any,
    ) -> LifecycleRow:
        fencing_token, stage, expected_completed, event = _parse_checkpoint_args(arg4, arg5, arg6, arg7)
        if "expected_completed" in kwargs:
            expected_completed = tuple(kwargs["expected_completed"])
        if "event" in kwargs:
            event = dict(kwargs["event"])
        async with _connection(self._source) as connection, connection.transaction():
            current_raw = await connection.fetchrow(
                "SELECT * FROM public.eap_environment_lifecycle WHERE customer_hash=$1 FOR UPDATE", customer_hash.lower()
            )
            current = self._row(current_raw)
            valid = _validate_checkpoint(
                current, worker_id, teardown_id, stage, expected_completed,
                fencing_token=fencing_token, now=datetime.now(timezone.utc),
            )
            if not valid:
                assert current is not None
                return current
            record = await connection.fetchrow(
                """UPDATE public.eap_environment_lifecycle
                   SET teardown_stages_completed=array_append(teardown_stages_completed, $4),
                       version=version+1, updated_at=NOW()
                   WHERE customer_hash=$1 AND claim_owner=$2 AND teardown_id=$3
                     AND ($5::bigint IS NULL OR claim_fencing_token=$5)
                   RETURNING *""",
                customer_hash.lower(), worker_id, teardown_id, stage, fencing_token,
            )
            if record is None:
                raise ValueError("claim owner or teardown id does not match")
            await self._outbox(connection, event)
            return self._row(record)  # type: ignore

    async def fail_claim(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        arg4: Any, arg5: Any = None, arg6: Any = None, arg7: Any = None,
        **kwargs: Any,
    ) -> LifecycleRow:
        fencing_token, error, next_retry_at, event = _parse_fail_args(arg4, arg5, arg6, arg7)
        if "event" in kwargs:
            event = dict(kwargs["event"])
        return await self._finish_claim(
            customer_hash, worker_id, teardown_id, fencing_token, "teardown_failed", error,
            next_retry_at, None, event,
        )

    async def complete_claim(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        arg4: Any, arg5: Any = None, arg6: Any = None,
        **kwargs: Any,
    ) -> LifecycleRow:
        fencing_token, required_stages, event = _parse_complete_args(arg4, arg5, arg6)
        if "event" in kwargs:
            event = dict(kwargs["event"])
        return await self._finish_claim(
            customer_hash, worker_id, teardown_id, fencing_token, "terminated", None, None,
            required_stages, event,
        )

    async def _finish_claim(
        self, customer_hash: str, worker_id: str, teardown_id: str,
        fencing_token: int | None,
        state: str, error: str | None, next_retry_at: datetime | None,
        required_stages: tuple[str, ...] | None,
        event: dict[str, Any],
    ) -> LifecycleRow:
        async with _connection(self._source) as connection, connection.transaction():
            current_raw = await connection.fetchrow(
                "SELECT * FROM public.eap_environment_lifecycle WHERE customer_hash=$1 FOR UPDATE", customer_hash.lower()
            )
            current = self._row(current_raw)
            _validate_checkpoint(
                current, worker_id, teardown_id, None, (),
                fencing_token=fencing_token, now=datetime.now(timezone.utc),
            )
            if required_stages is not None:
                assert current is not None
                if tuple(current.teardown_stages_completed) != required_stages:
                    raise ValueError("all teardown stages must be durably complete")

            record = await connection.fetchrow(
                """UPDATE public.eap_environment_lifecycle SET
                   state=$4, retry_count=retry_count + CASE WHEN $4='teardown_failed' THEN 1 ELSE 0 END,
                   next_retry_at=$5, last_error=$6, claim_owner=NULL, claim_expires_at=NULL,
                   version=version+1, updated_at=NOW()
                   WHERE customer_hash=$1 AND claim_owner=$2 AND teardown_id=$3
                     AND ($7::bigint IS NULL OR claim_fencing_token=$7)
                     AND ($8::text[] IS NULL OR teardown_stages_completed=$8::text[])
                   RETURNING *""",
                customer_hash.lower(), worker_id, teardown_id, state, next_retry_at,
                error, fencing_token, list(required_stages) if required_stages is not None else None,
            )
            if record is None:
                raise ValueError("claim owner or teardown id does not match")
            await self._outbox(connection, event)
            return self._row(record)  # type: ignore
