"""``FakeConnectorPool`` plus the ``remote_agents`` / ``remote_agent_sync_state`` tables.

remote_agent_sync.py tags every statement ``/* remote_agent_store:<op> */``.
Like the connector fake, this is not a SQL engine: it keys on the tag and
applies the operation to its own rows. It enforces what it can see:

* every op except ``due`` (the scheduler's cross-tenant enumeration of
  connector ids) and the advisory ``lock``/``unlock`` must carry
  ``tenant_id = $1``, and rows are filtered on that argument, so a statement
  that drops the filter fails here instead of leaking across tenants;
* ``due`` may read only ``public.tenant_connectors`` identifiers.

``held_elsewhere`` simulates another replica holding a connector's lock.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any

from tests.connector_store_fake import FakeConnectorPool

_MARKER = re.compile(r"/\*\s*remote_agent_store:([a-z_]+)\s*\*/")
_RA_COLS = ("external_id", "kind", "name", "model", "status", "version", "external_updated_at",
            "first_seen_at", "last_seen_at", "last_changed_at", "gone_at", "claimed_agent_id", "claimed_at",
            "raw_hash", "system_prompt", "environment_config", "user_metadata", "metrics")
_UNSCOPED_OPS = {"due", "lock", "unlock"}


class FakeRemoteAgentPool(FakeConnectorPool):
    def __init__(self) -> None:
        super().__init__()
        self.remote_agents: dict[tuple[str, str, str], dict[str, Any]] = {}
        self.snapshots: dict[tuple[str, str, str, str], dict[str, Any]] = {}
        self.sync_state: dict[tuple[str, str], dict[str, Any]] = {}
        self.locks: set[tuple[str, str]] = set()
        self.held_elsewhere: set[tuple[str, str]] = set()
        self.ops: list[str] = []
        # agent_registry rows written by the remote-agent claim, keyed by id.
        self.registry: dict[str, dict[str, Any]] = {}

    # -- dispatch ----------------------------------------------------------

    async def execute(self, sql: str, *args: Any) -> str:
        op = self._ra_op(sql)
        if op is None:
            return await super().execute(sql, *args)
        self.executed.append((sql, args))
        self._ra(op, sql, args)
        return "OK"

    async def fetch(self, sql: str = "", *args: Any, **_k: Any) -> list[Any]:
        op = self._ra_op(sql)
        if op is None:
            return await super().fetch(sql, *args)
        self.executed.append((sql, args))
        return self._ra(op, sql, args) or []

    async def fetchrow(self, sql: str = "", *args: Any, **_k: Any) -> Any:
        op = self._ra_op(sql)
        if op is None:
            return await super().fetchrow(sql, *args)
        self.executed.append((sql, args))
        rows = self._ra(op, sql, args)
        return rows[0] if rows else None

    async def fetchval(self, sql: str = "", *args: Any, **_k: Any) -> Any:
        op = self._ra_op(sql)
        if op is None:
            return await super().fetchval(sql, *args)
        self.executed.append((sql, args))
        return self._ra(op, sql, args)

    @staticmethod
    def _ra_op(sql: str) -> str | None:
        m = _MARKER.search(sql)
        return m.group(1) if m else None

    # -- helpers -------------------------------------------------------------

    def agents(self, tenant_id: str) -> list[dict[str, Any]]:
        return [r for (t, _, _), r in self.remote_agents.items() if t == tenant_id]

    def agent(self, tenant_id: str, external_id: str) -> dict[str, Any] | None:
        return next((r for (t, _, e), r in self.remote_agents.items() if t == tenant_id and e == external_id), None)

    def seed_connector(self, tenant_id: str, connector_id: str, provider_id: str, ref: str | None,
                       version: int | None = None, status: str = "connected") -> None:
        self.connectors[(tenant_id, connector_id)] = {
            "tenant_id": tenant_id, "connector_id": connector_id, "provider_id": provider_id,
            "display_name": provider_id, "status": status, "credential_expires_at": None,
            "last_tested_at": None, "last_scan_at": None, "last_scan_status": None, "last_scan_error": None,
            "metadata": "{}", "created_at": datetime(2026, 1, 1), "credentials_ref": ref,
            "credentials_version": version, "credentials_ciphertext": None,
            "last_scan_result": None,
        }

    # -- the tables ------------------------------------------------------------

    def _ra(self, op: str, sql: str, args: tuple[Any, ...]) -> Any:
        self.ops.append(op)
        flat = " ".join(sql.split())
        if op not in _UNSCOPED_OPS:
            scoped = "VALUES ($1," in flat if op in ("upsert", "state_put", "snapshot_insert") else "tenant_id = $1" in flat
            if not scoped:
                raise AssertionError(f"remote_agent_store:{op} is not scoped by tenant_id = $1: {flat}")
            # A conflict update must not be able to touch another tenant's row either.
            if op in ("upsert", "state_put") and "tenant_id = $1" not in flat:
                raise AssertionError(f"remote_agent_store:{op} conflict update is not scoped by tenant_id = $1")

        if op == "due":
            if "FROM public.tenant_connectors" not in flat or "remote_agents" in flat:
                raise AssertionError("remote_agent_store:due may only enumerate tenant_connectors identifiers")
            providers = set(args[0])
            rows = [r for r in self.connectors.values()
                    if r["status"] == "connected" and r.get("credentials_ref") and r["provider_id"] in providers]
            return [{"tenant_id": r["tenant_id"], "connector_id": r["connector_id"], "provider_id": r["provider_id"]}
                    for r in sorted(rows, key=lambda r: (r["tenant_id"], r["connector_id"]))]

        if op in ("lock", "unlock"):
            key = (args[0], args[1])
            if op == "lock":
                if key in self.held_elsewhere or key in self.locks:
                    return False
                self.locks.add(key)
                return True
            self.locks.discard(key)
            return True

        tenant = args[0]
        if op == "connector":
            rows = [r for (t, _), r in self.connectors.items() if t == tenant]
            hit = next((r for r in rows if r["connector_id"] == args[1]), None) or next(
                (r for r in rows if r["provider_id"] == args[1]), None)
            return [{k: hit.get(k) for k in ("connector_id", "provider_id", "status", "credentials_ref",
                                             "credentials_version", "credentials_ciphertext", "metadata")}] if hit else []

        if op in ("existing", "list"):
            rows = [dict(r) for (t, c, _), r in self.remote_agents.items() if t == tenant and c == args[1]]
            if op == "list":
                rows.sort(key=lambda r: (r["gone_at"] is not None, r["kind"], r["name"] is None, r["name"] or "", r["external_id"]))
            return [{k: r.get(k) for k in _RA_COLS} for r in rows]

        if op == "existing_one":
            r = self.remote_agents.get((tenant, args[1], args[2]))
            return [{k: r.get(k) for k in _RA_COLS}] if r else []

        if op == "snapshot_insert":
            (_, connector_id, external_id, raw_hash, kind, name, model, status, version,
             system_prompt, tools, environment_config, user_metadata, metrics, raw, observed_at) = args
            key = (tenant, connector_id, external_id, raw_hash)
            if key not in self.snapshots:
                self.snapshots[key] = {
                    "tenant_id": tenant,
                    "connector_id": connector_id,
                    "external_id": external_id,
                    "raw_hash": raw_hash,
                    "kind": kind,
                    "name": name,
                    "model": model,
                    "status": status,
                    "version": version,
                    "system_prompt": system_prompt,
                    "tools": json.loads(tools) if isinstance(tools, str) else tools,
                    "environment_config": json.loads(environment_config) if isinstance(environment_config, str) else environment_config,
                    "user_metadata": json.loads(user_metadata) if isinstance(user_metadata, str) else user_metadata,
                    "metrics": json.loads(metrics) if isinstance(metrics, str) else metrics,
                    "raw": json.loads(raw) if isinstance(raw, str) else raw,
                    "observed_at": observed_at,
                }
            return None

        if op == "snapshots_list":
            rows = [r for (t, c, e, _), r in self.snapshots.items() if t == tenant and c == args[1] and e == args[2]]
            rows.sort(key=lambda r: r["observed_at"], reverse=True)
            return [dict(r) for r in rows]

        if op == "upsert":
            if len(args) == 17:
                (_, connector_id, provider_id, external_id, kind, name, model, status, version,
                 ext_updated, at, raw, raw_hash, system_prompt, env_config, user_meta, metrics) = args
            else:
                (_, connector_id, provider_id, external_id, kind, name, model, status, version,
                 ext_updated, at, raw) = args
                raw_hash = None
                system_prompt = None
                env_config = "{}"
                user_meta = "{}"
                metrics = "{}"
            key = (tenant, connector_id, external_id)
            prior = self.remote_agents.get(key)
            row = {
                "tenant_id": tenant, "connector_id": connector_id, "provider_id": provider_id,
                "external_id": external_id, "kind": kind, "name": name, "model": model, "status": status,
                "version": version, "external_updated_at": ext_updated,
                "first_seen_at": prior["first_seen_at"] if prior else at,
                "last_seen_at": at, "last_changed_at": at, "gone_at": None,
                "raw": json.loads(raw) if isinstance(raw, str) else raw,
                # The conflict update does not touch the claim link.
                "claimed_agent_id": prior["claimed_agent_id"] if prior else None,
                "claimed_at": prior["claimed_at"] if prior else None,
                "raw_hash": raw_hash,
                "system_prompt": system_prompt,
                "environment_config": json.loads(env_config) if isinstance(env_config, str) else (env_config or {}),
                "user_metadata": json.loads(user_meta) if isinstance(user_meta, str) else (user_meta or {}),
                "metrics": json.loads(metrics) if isinstance(metrics, str) else (metrics or {}),
            }
            self.remote_agents[key] = row
            return [{k: row.get(k) for k in _RA_COLS}]

        if op == "touch":
            _, connector_id, at, ids = args
            for ext in ids:
                r = self.remote_agents.get((tenant, connector_id, ext))
                if r is not None:
                    r["last_seen_at"] = at
            return None

        if op == "mark_gone":
            _, connector_id, at, ids = args
            out = []
            for ext in ids:
                r = self.remote_agents.get((tenant, connector_id, ext))
                if r is not None and r["gone_at"] is None:
                    r["gone_at"] = at
                    r["last_changed_at"] = at
                    out.append({"external_id": ext, "gone_at": at})
            return out

        if op == "discovery":
            out = []
            for (t, c, _), r in sorted(self.remote_agents.items()):
                conn = self.connectors.get((t, c))
                if t == tenant and r["gone_at"] is None and conn is not None and conn["status"] == "connected":
                    out.append({k: r.get(k) for k in ("connector_id", "provider_id", "external_id", "kind", "name", "model",
                                                  "status", "version", "external_updated_at", "first_seen_at",
                                                  "last_seen_at", "claimed_agent_id", "raw_hash", "system_prompt",
                                                  "environment_config", "user_metadata", "metrics")})
            return out

        if op == "registry_upsert":
            (_, agent_id, name, display_name, description, model_provider, model_name, owner, owner_id, config) = args
            key = str(agent_id)
            prior = self.registry.get(key)
            if prior is not None and prior["tenant_id"] != tenant:
                return []  # ON CONFLICT ... WHERE tenant_id = $1: another tenant's row is untouched
            if prior is None and any(r["tenant_id"] == tenant and r["name"] == name for r in self.registry.values()):
                raise AssertionError(f"duplicate agent_registry (tenant_id, name) {tenant}/{name}")
            row = {"id": key, "tenant_id": tenant, "name": name, "display_name": display_name,
                   "description": description, "model_provider": model_provider, "model_name": model_name,
                   "owner": owner if prior is None else (prior["owner"] or owner),
                   "owner_id": owner_id, "config": json.loads(config),
                   "lifecycle_state": prior["lifecycle_state"] if prior else "enrolled",
                   "status": prior["status"] if prior else "active"}
            self.registry[key] = row
            return [{"id": agent_id}]

        if op == "claim_link":
            _, connector_id, external_id, agent_id, at = args
            r = self.remote_agents.get((tenant, connector_id, external_id))
            if r is None or r["gone_at"] is not None or r["claimed_agent_id"] is not None:
                return []
            r["claimed_agent_id"] = agent_id
            r["claimed_at"] = at
            return [{k: r[k] for k in _RA_COLS}]

        if op == "state_get":
            r = self.sync_state.get((tenant, args[1]))
            return [dict(r)] if r else []

        if op == "state_put":
            (_, connector_id, provider_id, mode, last_poll, last_success, last_error, next_poll, failures) = args
            self.sync_state[(tenant, connector_id)] = {
                "provider_id": provider_id, "mode": mode, "last_poll_at": last_poll, "last_success_at": last_success,
                "last_error": last_error, "next_poll_at": next_poll, "consecutive_failures": failures,
            }
            return None

        raise AssertionError(f"unknown remote_agent_store op {op!r}")
