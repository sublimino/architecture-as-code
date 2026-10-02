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
