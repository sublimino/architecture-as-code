"""Live discovery (a DB pool is present) reports only what a real source said.

W22. A Playwright capture of /discovery showed demo rows and PASS/REVIEW
pillar verdicts on a live estate. The dashboard half of that is a demo-mode
default (see the dashboard's noFabricatedLiterals guard); this suite pins the
backend half: with a pool present, ``list_discovery_workloads`` must

* never serve the in-memory seed rows (``_ensure_seeded`` / the fixture
  branch), and never seed the in-memory store as a side effect;
* never invent a pillar verdict. No evaluator runs on the discovery path, so
  every pillar is ``not_assessed`` unless a stored scan finding backs it;
* map a remote agent whose provider reported no owner, namespace or metrics
  to absent fields, not to placeholders.

The pool is a stub that answers each discovery query by its table, so every
DB-mode branch (IdP, local K8s, external registrations, remote agents) yields
a row. No network, no database.
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any

import pytest

import api_compat
import remote_agent_sync

TENANT = "tenant-w22-live"

# Every name the in-memory seed (api_compat._ensure_seeded and the fixture
# branch of list_discovery_workloads) can put on the discovery list.
SEED_NAMES = {
    "Inventory Agent",
    "Triage Agent",
    "Financial Risk Intelligence Agent",
    "Customer Support Triage Assistant",
    "cloudrun-prompt-processor",
    "n8n-support-router",
    "afm-staging-collector",
    "prod-eu-validator",
    "svc-signalloom-build",
}

_T0 = datetime(2026, 10, 17, 9, 0, tzinfo=timezone.utc)


class _DiscoveryPool:
    """Answers the four DB-mode discovery reads, one row each."""

    async def fetch(self, sql: str, *args: Any) -> list[dict[str, Any]]:
        if "nhi_discovered_accounts" in sql:
            return [
                {"id": "nhi-clean", "account_name": "svc-clean", "directory_source": "okta",
                 "owner_email": None, "privilege_level": "standard", "status": "needs_triage",
                 "findings": [], "scan_count": 1, "first_discovered_at": _T0, "last_seen_at": _T0},
                {"id": "nhi-stale", "account_name": "svc-stale", "directory_source": "okta",
                 "owner_email": None, "privilege_level": "standard", "status": "needs_triage",
                 "findings": ["stale_credential", "unrotated_secret"], "scan_count": 1,
                 "first_discovered_at": _T0, "last_seen_at": _T0},
            ]
        if "agent_registry" in sql:
            return [{"id": "11111111-1111-1111-1111-111111111111", "name": "claimed-pod",
                     "lifecycle_state": "active", "owner": None, "model_name": None, "created_at": _T0,
                     "config": {}, "claim_id": "claim-1", "claim_namespace": "team-a",
                     "spiffe_id": None, "claim_status": "granted"}]
        if "external_agent_registrations" in sql:
            return [{"agent_id": "ext-1", "host_id": "h", "host_os": "linux", "runtime_profile": "p",
                     "enrollment_status": "enrolled", "metadata": {}, "spiffe_id_pattern": None,
                     "created_at": _T0, "enrolled_at": _T0, "revoked_at": None}]
        raise AssertionError(f"unexpected discovery query: {sql[:80]}")


_REMOTE_ROW = {
    "connector_id": "conn-claude-01", "provider_id": "claude", "external_id": "agent_live_1",
    "kind": "agent", "name": "Daily News Jokester", "model": "claude-opus-5-5", "status": None,
    "version": "3", "external_updated_at": _T0, "first_seen_at": _T0, "last_seen_at": _T0,
    "claimed_agent_id": None, "raw_hash": "abc123", "system_prompt": None,
    "environment_config": {}, "user_metadata": {"workspace_id": "wrkspc_from_creds"}, "metrics": {},
}


@pytest.fixture
def live_discovery(monkeypatch: pytest.MonkeyPatch):
    async def _pool():
        return _DiscoveryPool()

    async def _no_kernel_view():
        return []

    async def _remote_rows(_pool: Any, tenant_id: str):
        assert tenant_id == TENANT
        return [dict(_REMOTE_ROW)]

    monkeypatch.setattr(api_compat, "_get_pool", _pool)
    monkeypatch.setattr(api_compat, "_fetch_discovered_agents", _no_kernel_view)
    monkeypatch.setattr(remote_agent_sync, "discovery_rows", _remote_rows)
    for store in (api_compat._AGENTS, api_compat._NHI_ACCOUNTS, api_compat._TENANT_CONNECTORS):
        store.pop(TENANT, None)

    def _call():
        return asyncio.run(api_compat.list_discovery_workloads(
            tenant_id=TENANT, source=None, status=None, namespace=None, search=None, page=1, limit=100,
        )).model_dump()

    yield _call
    for store in (api_compat._AGENTS, api_compat._NHI_ACCOUNTS):
        store.pop(TENANT, None)


def test_live_discovery_serves_no_seed_rows_and_seeds_nothing(live_discovery):
    body = live_discovery()
    names = {w["name"] for w in body["workloads"]}
    assert names == {"svc-clean", "svc-stale", "claimed-pod", "ext-1", "Daily News Jokester"}
    assert names & SEED_NAMES == set()
    # Serving the live list must not populate the in-memory demo store either.
    assert TENANT not in api_compat._AGENTS
    assert TENANT not in api_compat._NHI_ACCOUNTS


def test_live_discovery_invents_no_pillar_verdict(live_discovery):
    rows = {w["name"]: w for w in live_discovery()["workloads"]}
    pillars = ("config", "content", "supply_chain", "eu_ai_act")

    # Nothing evaluated these: every pillar is not_assessed, in both fields.
    for name in ("claimed-pod", "ext-1", "Daily News Jokester"):
        for field in ("recommendations", "control_recommendations"):
            assert {p: rows[name][field][p] for p in pillars} == dict.fromkeys(pillars, "not_assessed"), (name, field)

    # An IdP account with no findings has no evidence either way.
    clean = rows["svc-clean"]["recommendations"]
    assert (clean["config"], clean["supply_chain"], clean["eu_ai_act"]) == ("not_assessed",) * 3
    assert clean["content"] == "not_applicable"

    # A stored scan finding is evidence, and only that is reported.
    stale = rows["svc-stale"]["recommendations"]
    assert (stale["config"], stale["supply_chain"], stale["eu_ai_act"]) == ("warning", "recommended", "not_assessed")

    assert "pass" not in {w["recommendations"][p] for w in rows.values() for p in pillars}


def test_live_remote_agent_maps_unreported_fields_to_absent(live_discovery):
    (remote,) = [w for w in live_discovery()["workloads"] if w["metadata"].get("provider_id") == "claude"]
    assert remote["owner"] is None
    assert remote["namespace"] is None
    assert remote["metadata"]["user_metadata"] == {"workspace_id": "wrkspc_from_creds"}
    assert remote["metadata"]["metrics"] == {}
    assert remote["last_seen_at"] == "2026-10-17T09:00:00Z"
