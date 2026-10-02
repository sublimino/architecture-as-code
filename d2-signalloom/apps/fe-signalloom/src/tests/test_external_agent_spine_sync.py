"""External-agent revocation must clamp the revoked AGENT's delegation, for its tenant.

Found while giving the signal-ingest calls a tenant: _execute_revocation called
``clamp_claim_delegation_in_spine(tenant_id, str(agent_uuid))`` positionally, i.e. with
agent_id=tenant_id, so the clamp named the tenant and never the revoked agent; and the claim path
passed ``tenant_id=`` to sync_claim_delegation_to_spine, a keyword it never had, so every
external-agent claim raised TypeError into a swallowing except and never reached the spine.
"""
from __future__ import annotations

import asyncio
import uuid

import api_compat
import external_agent_registration as ear
from db.connection import set_pool_for_testing


def test_revocation_clamps_the_revoked_agent_for_its_tenant(monkeypatch):
    set_pool_for_testing(None)
    calls = []

    async def fake_clamp(*args, **kwargs):
        calls.append((args, kwargs))
        return True

    async def no_audit(*args, **kwargs):
        return None

    monkeypatch.setattr(ear, "clamp_claim_delegation_in_spine", fake_clamp)
    monkeypatch.setattr(ear, "_audit_log_external_agent", no_audit)
    monkeypatch.setitem(ear._EXTERNAL_REGISTRATIONS, "kusari", {"host-agent-1": {"enrollment_status": "active"}})

    principal = api_compat.Principal(tenant="kusari", subject="alice", email=None)
    asyncio.run(ear._execute_revocation("kusari", "host-agent-1", "test", principal))

    agent_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, "kusari:host-agent-1"))
    assert len(calls) == 1
    args, kwargs = calls[0]
    assert args[0] == agent_uuid, f"clamp targeted {args[0]!r}, not the revoked agent"
    assert kwargs.get("tenant") == "kusari"


def test_db_backed_claim_reaches_the_spine_for_its_tenant(monkeypatch):
    """Reported by lanes-docs: on the Postgres branch the sync call's arguments read ``reg_item``,
    which only the in-memory branch binds, so every DB-backed external-agent claim raised
    UnboundLocalError into the swallowing except and never reached the spine."""
    from contextlib import asynccontextmanager

    reg = {
        "tenant_id": "kusari", "agent_id": "host-agent-1", "host_id": "host-7", "host_os": "linux",
        "runtime_profile": "nono-0.73.0-standard", "enrollment_status": "registered",
        "allocated_token_budget": 1000, "spiffe_id_pattern": None,
    }

    class Conn:
        async def fetchrow(self, sql, *args):
            return reg if "external_agent_registrations" in sql else None

        async def execute(self, *args):
            return "OK"

    @asynccontextmanager
    async def fake_write(_pool):
        yield Conn()

    async def fake_pool():
        return object()

    synced = []

    async def fake_sync(**kwargs):
        synced.append(kwargs)
        return True

    async def no_audit(*args, **kwargs):
        return None

    monkeypatch.setattr(api_compat, "_get_pool", fake_pool)
    monkeypatch.setattr(api_compat, "_write", fake_write)
    monkeypatch.setattr(ear, "sync_claim_delegation_to_spine", fake_sync)
    monkeypatch.setattr(ear, "_audit_log_external_agent", no_audit)

    principal = api_compat.Principal(tenant="kusari", subject="alice", email=None)
    asyncio.run(ear.claim_external_agent_handler("host-agent-1", principal, None))

    assert len(synced) == 1, "the DB-backed claim never reached the spine"
    assert synced[0]["tenant"] == "kusari"
    assert synced[0]["metadata"]["host_id"] == "host-7"
