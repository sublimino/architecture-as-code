"""An asyncpg stand-in that holds the ``tenant_connectors`` table in memory.

The connectors router tags every statement it issues against
``public.tenant_connectors`` with a ``/* connector_store:<op> */`` marker. This
fake recognises those markers and applies the operation to its own rows, so a
test can drop every in-process dict, keep this pool, and read back exactly what
the router persisted -- the same thing a pod restart does to the real service.

It is not a SQL engine, so it cannot tell whether a WHERE clause is present.
It checks the next best thing: every store statement must scope itself with
``tenant_id = $1``, and the fake filters on that argument. A statement that
drops the filter fails loudly here rather than leaking across tenants quietly.
The SQL itself is exercised against a real PostgreSQL by
``test_connector_store_postgres.py`` when ``DATABASE_URL`` is set.

Any other statement (audit inserts and the like) is recorded in ``executed``
and answered with an empty read, as the previous fake did.
"""
from __future__ import annotations

import json
import re
from contextlib import asynccontextmanager
from typing import Any

_MARKER = re.compile(r"/\*\s*connector_store:([a-z_]+)\s*\*/")

_COLUMNS = (
    "connector_id", "provider_id", "display_name", "status", "credential_expires_at",
    "last_tested_at", "last_scan_at", "last_scan_status", "last_scan_error", "metadata",
    "created_at",
)


class _Conn:
    def __init__(self, pool: "FakeConnectorPool") -> None:
        self._pool = pool

    @asynccontextmanager
    async def transaction(self):
        yield self

    async def execute(self, sql: str, *args: Any) -> str:
        return await self._pool.execute(sql, *args)

    async def fetch(self, sql: str = "", *args: Any, **_k: Any) -> list[Any]:
        return await self._pool.fetch(sql, *args)

    async def fetchrow(self, sql: str = "", *args: Any, **_k: Any) -> Any:
        return await self._pool.fetchrow(sql, *args)

    async def fetchval(self, sql: str = "", *args: Any, **_k: Any) -> Any:
        return await self._pool.fetchval(sql, *args)


class FakeConnectorPool:
    """Records every statement; keeps ``tenant_connectors`` rows across app restarts."""

    def __init__(self) -> None:
        self.executed: list[tuple[str, tuple[Any, ...]]] = []
        # (tenant_id, connector_id) -> full row, including credentials_ciphertext
        # and last_scan_result exactly as the router wrote them.
        self.connectors: dict[tuple[str, str], dict[str, Any]] = {}

    # -- asyncpg surface ---------------------------------------------------

    @asynccontextmanager
    async def acquire(self):
        yield _Conn(self)

    async def execute(self, sql: str, *args: Any) -> str:
        self.executed.append((sql, args))
        op = self._op(sql)
        if op is not None:
            self._apply(op, sql, args)
        return "OK"

    async def fetch(self, sql: str = "", *args: Any, **_k: Any) -> list[Any]:
        self.executed.append((sql, args))
        op = self._op(sql)
        if op is None:
            return []
        return self._apply(op, sql, args) or []

    async def fetchrow(self, sql: str = "", *args: Any, **_k: Any) -> Any:
        self.executed.append((sql, args))
        op = self._op(sql)
        if op is None:
            return None
        rows = self._apply(op, sql, args)
        return rows[0] if rows else None

    async def fetchval(self, sql: str = "", *args: Any, **_k: Any) -> Any:
        self.executed.append((sql, args))
        op = self._op(sql)
        if op is None:
            return None
        return self._apply(op, sql, args)

    async def close(self) -> None:
        pass

    # -- helpers for assertions -------------------------------------------

    def audit_rows(self, event_type: str) -> list[dict[str, Any]]:
        return [
            {"tenant": args[0], "event_type": args[1], "actor": args[4], "detail": json.loads(args[5])}
            for sql, args in self.executed
            if "INSERT INTO audit_events" in sql and len(args) >= 6 and args[1] == event_type
        ]

    def row(self, tenant_id: str, connector_id: str) -> dict[str, Any] | None:
        return self.connectors.get((tenant_id, connector_id))

    # -- the table ----------------------------------------------------------

    @staticmethod
    def _op(sql: str) -> str | None:
        m = _MARKER.search(sql)
        return m.group(1) if m else None

    def _tenant_rows(self, tenant_id: str) -> list[dict[str, Any]]:
        rows = [r for (t, _), r in self.connectors.items() if t == tenant_id]
        return sorted(rows, key=lambda r: (r["created_at"], r["connector_id"]))

    @staticmethod
    def _public(row: dict[str, Any], *, full: bool = False) -> dict[str, Any]:
        out = {c: row.get(c) for c in _COLUMNS}
        if full:
            out["credentials_ref"] = row.get("credentials_ref")
            out["credentials_version"] = row.get("credentials_version")
            out["credentials_ciphertext"] = row.get("credentials_ciphertext")
            out["last_scan_result"] = row.get("last_scan_result")
        return out

    def _apply(self, op: str, sql: str, args: tuple[Any, ...]) -> Any:
        flat = " ".join(sql.split())
        # An INSERT scopes its row by writing tenant_id as the first value.
        scoped = "(tenant_id, " in flat and "VALUES ($1," in flat if op == "insert" else "tenant_id = $1" in flat
        if not scoped:
            raise AssertionError(f"connector_store:{op} is not scoped by tenant_id = $1: {flat}")
        tenant = args[0]

        if op == "list":
            return [self._public(r) for r in self._tenant_rows(tenant)]

        if op == "count":
            return len(self._tenant_rows(tenant))

        if op == "get":
            key = args[1]
            rows = self._tenant_rows(tenant)
            hit = next((r for r in rows if r["connector_id"] == key), None) or next(
                (r for r in rows if r["provider_id"] == key), None)
            return [self._public(hit, full=True)] if hit else []

        if op == "get_provider":
            hit = next((r for r in self._tenant_rows(tenant) if r["provider_id"] == args[1]), None)
            return [self._public(hit, full=True)] if hit else []

        if op == "insert":
            _, connector_id, provider_id, display_name, expires, metadata, ref, version, created_at = args
            if (tenant, connector_id) in self.connectors or any(
                    r["provider_id"] == provider_id for r in self._tenant_rows(tenant)):
                raise AssertionError("unique violation on tenant_connectors")
            self.connectors[(tenant, connector_id)] = {
                "tenant_id": tenant, "connector_id": connector_id, "provider_id": provider_id,
                "display_name": display_name, "status": "connected", "credential_expires_at": expires,
                "last_tested_at": None, "last_scan_at": None, "last_scan_status": None,
                "last_scan_error": None, "metadata": metadata, "created_at": created_at,
                "credentials_ref": ref, "credentials_version": version,
                "credentials_ciphertext": None, "last_scan_result": None,
            }
            return None

        row = self.connectors.get((tenant, args[1]))
        if row is None:
            return []

        if op == "reconnect":
            _, _, display_name, metadata, expires, ref, version = args
            row.update(status="connected", display_name=display_name, metadata=metadata,
                       credential_expires_at=expires)
            if ref is not None:
                # New credentials replace the reference and drop any old ciphertext,
                # as the CHECK in migration 078 requires.
                row.update(credentials_ref=ref, credentials_version=version, credentials_ciphertext=None)
        elif op == "set_status":
            row["status"] = args[2]
            return [self._public(row)]
        elif op == "disconnect":
            row.update(status="disconnected", credentials_ref=None, credentials_version=None,
                       credentials_ciphertext=None, last_scan_result=None)
        elif op == "stamp_tested":
            row["last_tested_at"] = args[2]
        elif op == "record_scan":
            _, _, scan_at, status, error, result = args
            if scan_at is not None:
                row["last_scan_at"] = scan_at
            row.update(last_scan_status=status, last_scan_error=error, last_scan_result=result)
        else:
            raise AssertionError(f"unknown connector_store op {op!r}")
        return None
