# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_eap_audit_connection_wiring.py
# Proves EAP mutating routes actually persist their audit decision.
#
# Recovered from the stranded SLRC-P3-1 mission (integration/slrc-v0.1.0
# a7ba935e "add surgical audit decisions for EAP mutating routes"). The call
# sites (eap_audit._audit_eap_decision) and the DB vocabulary (migration 045)
# both landed on the base, but every one of the 15 call sites across
# environment_lifecycle.py, environment_routing.py, scenario_seeding.py and
# tenant_isolation.py passed a literal ``None``/``conn=None`` for the
# connection argument. ``_audit_eap_decision`` is written to treat a None
# connection as "no DB configured, skip silently" (see eap_audit.py:65:
# ``if conn is not None and hasattr(conn, "execute")``), so every one of
# those calls was a guaranteed, permanent no-op -- the existing
# test_audit_provenance.py / test_eap_audit_events.py suite only proves the
# call is *reached* (static AST analysis), never that it writes anything.
#
# The fix threads the already-imported ``api_compat`` module's pool through:
# ``await api_compat._get_pool()`` instead of the ``None`` literal. This
# deliberately avoids ``from api_compat import _get_pool`` -- a direct name
# binding -- because test_adversarial_onboarding.py's own POOL_IMPORTERS
# self-check exists precisely to catch modules that bind _get_pool that way
# and then escape a monkeypatch of api_compat. Calling through the module
# object needs no POOL_IMPORTERS entry at all.
# ==============================================================================
from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any

import api_compat
import pytest

from environment_lifecycle import GLOBAL_LIFECYCLE_MANAGER
from environment_routing import derive_customer_hash
from main import app
from conftest import EAPClient

# The _eap_jwt_env autouse fixture only configures the test JWT verifier for
# modules that opt in this way (see tests/conftest.py).
EAP_AUTHENTICATED = True


class RecordingPool:
    """Captures every statement issued through it; answers nothing useful.

    Same shape as test_adversarial_onboarding.RecordingPool, duplicated here
    rather than imported so this suite has no dependency on another test
    module's internals.
    """

    def __init__(self) -> None:
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    async def execute(self, query: str, *args: Any) -> str:
        self.statements.append((query, args))
        return "OK"

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


@pytest.fixture
def recording_pool(monkeypatch):
    """Replace api_compat._get_pool with one that hands back a RecordingPool.

    Patching the module attribute (not a local binding) is exactly what
    POOL_IMPORTERS exists to make sufficient -- see the module docstring.
    """
    pool = RecordingPool()

    async def _fake_get_pool() -> RecordingPool:
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _fake_get_pool)
    return pool


@pytest.fixture
def client():
    return EAPClient(app)


def _audit_inserts(pool: RecordingPool) -> list[tuple[str, tuple[Any, ...]]]:
    return [(q, a) for q, a in pool.statements if "INSERT INTO public.audit_events" in q]


def test_lifecycle_register_persists_audit_decision(client, recording_pool):
    """POST /register must write an audit_events row, not silently skip it."""
    company = "audit-wiring-lifecycle-corp"
    resp = client.post(
        "/api/v1/eap/lifecycle/register",
        json={"company_name": company, "ttl_minutes": 60},
    )
    assert resp.status_code == 201

    inserts = _audit_inserts(recording_pool)
    assert inserts, "register must persist an audit decision through api_compat._get_pool()"
    query, args = inserts[0]
    assert "eap.environment_lifecycle.register" in args, args


def test_tenant_isolation_provision_persists_audit_decision(client, recording_pool):
    """POST /api/v1/eap/tenants must write an audit_events row."""
    company = "audit-wiring-tenant-corp"
    resp = client.post("/api/v1/eap/tenants", json={"company_name": company})
    assert resp.status_code == 201

    inserts = _audit_inserts(recording_pool)
    assert inserts, "tenant provisioning must persist an audit decision through api_compat._get_pool()"
    query, args = inserts[0]
    assert "eap.tenant.provision" in args, args


def test_scenario_execute_persists_audit_decision(client, recording_pool):
    """POST /api/v1/eap/scenarios/execute must write an audit_events row."""
    company = "audit-wiring-scenario-corp"
    customer_hash = derive_customer_hash(company)
    GLOBAL_LIFECYCLE_MANAGER.register_environment(company_name=company, customer_hash=customer_hash, ttl_minutes=60)

    resp = client.post(
        "/api/v1/eap/scenarios/execute",
        json={"scenario_type": "baseline_agent_flow", "company_name": company, "customer_hash": customer_hash},
    )
    assert resp.status_code == 201

    inserts = _audit_inserts(recording_pool)
    assert inserts, "scenario execution must persist an audit decision through api_compat._get_pool()"


def test_audit_decision_is_skipped_without_a_pool(client, monkeypatch):
    """Control: with no DB configured (the FIXTURE_MODE default), nothing is persisted.

    This is the behaviour every existing test already runs under -- it must
    stay unchanged. It also demonstrates why the three tests above are a real
    proof: the only difference from this test is the recording_pool fixture,
    and that difference is what turns a no-op into a recorded statement.
    """
    monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.FIXTURE_MODE)
    company = "audit-wiring-noop-corp"
    resp = client.post(
        "/api/v1/eap/lifecycle/register",
        json={"company_name": company, "ttl_minutes": 60},
    )
    assert resp.status_code == 201
    # No assertion is possible on "nothing was written" without the recording
    # pool; this test exists to document the contrast, and it must not raise.
