"""A mutating endpoint and its audit record must commit or roll back together.

Every statement issued against an ``asyncpg.Pool`` is its own autocommit
transaction. Handlers that did their business write and then their audit insert
as two pool calls therefore had no atomicity: when the audit insert failed, the
business write had already committed, the exception propagated, and the caller
got a 500 for a change that persisted.

That is not hypothetical. The ``audit_events`` CHECK constraint rejected every
event type the code emitted until migration 007, so
``PATCH /tenant/settings/preferences`` saved the user's preferences and then
reported failure. The user saw an error; the data was in the database. For a
product whose output is regulatory evidence, a business write with no matching
audit record is worse than no write at all.

``api_compat._write()`` is the fix. These tests pin both halves of it down:

* the mutation and the audit row land together on success, and
* **an audit failure leaves no trace of the mutation** -- asserted on stored
  state, not merely on the 500 the caller sees.

The fake below keeps committed and uncommitted state genuinely separate, which
is what lets the third property be tested at all: several handlers finish with
``return await tenant_settings(...)``, a re-read that acquires its *own*
connection and therefore must run after the commit. A fake that applied writes
immediately could not tell that re-read apart from one made inside the
transaction -- and a re-read moved inside would fail silently, returning stale
values rather than raising.
"""
from __future__ import annotations

import ast
import re
import copy
import json
import socket
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import asyncpg
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import onboarding
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

API_COMPAT = Path(api_compat.__file__)

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# The in-memory stores are module-level and outlive individual tests, so every
# subject here owns a tenant no other test file writes to.
SUBJECT_TENANTS = {
    "tx-pooled": "tenant-tx-pooled",
    "tx-memory": "tenant-tx-memory",
}


# ---------------------------------------------------------------------------
# Recording fake Postgres with a committed/uncommitted split
# ---------------------------------------------------------------------------

@dataclass
class _State:
    """Every table these handlers touch. Deep-copied to stage a transaction."""

    agent_registry: list[dict[str, Any]] = field(default_factory=list)
    agent_credentials: list[dict[str, Any]] = field(default_factory=list)
    audit_events: list[dict[str, Any]] = field(default_factory=list)
    api_keys: list[dict[str, Any]] = field(default_factory=list)
    tenant_settings: dict[str, dict[str, Any]] = field(default_factory=dict)
    nhi_accounts: dict[str, dict[str, Any]] = field(default_factory=dict)
    tenant_onboarding: dict[str, dict[str, Any]] = field(default_factory=dict)


class AuditInsertRejected(asyncpg.CheckViolationError):
    """What migration 007 existed to stop: the constraint refusing an event."""


class _FakeConnection:
    """One connection. Reads and writes hit staged state while in a transaction.

    Outside a transaction it operates directly on committed state, exactly as a
    pooled autocommit statement does.
    """

    def __init__(self, pool: "FakePostgres") -> None:
        self._pool = pool
        self._state = pool.committed

    async def execute(self, query: str, *args: Any) -> None:
        self._pool.apply(self._state, query, *args)

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        return self._pool.read_one(self._state, query, *args)

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        return self._pool.read_many(self._state, query, *args)

    @asynccontextmanager
    async def transaction(self) -> AsyncIterator[None]:
        self._state = copy.deepcopy(self._pool.committed)
        try:
            yield
        except BaseException:
            self._state = self._pool.committed
            self._pool.rollbacks += 1
            raise
        self._pool.committed = self._state
        self._pool.commits += 1


class FakePostgres:
    """Just enough asyncpg.Pool to drive the write handlers and record what stuck.

    Pool-level statements see committed state only -- so a read taken through
    the pool while a transaction is open observes nothing of it, which is what a
    second connection really does.
    """

    def __init__(self, *, fail_audit: bool = False) -> None:
        self.fail_audit = fail_audit
        self.committed = _State()
        self.commits = 0
        self.rollbacks = 0

    # -- pool-level (autocommit, committed state) ---------------------------

    @asynccontextmanager
    async def acquire(self) -> AsyncIterator[_FakeConnection]:
        yield _FakeConnection(self)

    async def execute(self, query: str, *args: Any) -> None:
        self.apply(self.committed, query, *args)

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        return self.read_one(self.committed, query, *args)

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        return self.read_many(self.committed, query, *args)

    # -- statement dispatch --------------------------------------------------

    def apply(self, state: _State, query: str, *args: Any) -> None:
        if "INSERT INTO audit_events" in query:
            if self.fail_audit:
                raise AuditInsertRejected(
                    'new row for relation "audit_events" violates check '
                    'constraint "audit_events_event_type_check"',
                )
            tenant_id, event_type, agent_id, agent_name, actor, detail = args
            state.audit_events.append(
                {
                    "tenant_id": tenant_id,
                    "event_type": event_type,
                    "agent_id": agent_id,
                    "agent_name": agent_name,
                    "actor": actor,
                    "detail": detail,
                },
            )
            return
        if "INSERT INTO public.agent_credentials" in query:
            tenant_id, agent_id, token_sha256, expires_at = args
            state.agent_credentials.append(
                {
                    "tenant_id": tenant_id,
                    "agent_id": agent_id,
                    "token_sha256": token_sha256,
                    "expires_at": expires_at,
                    "revoked_at": None,
                    "revoked_by": None,
                },
            )
            return
        if query.startswith("INSERT INTO tenant_settings"):
            tenant_id, org_name = args
            state.tenant_settings.setdefault(tenant_id, _fresh_tenant_settings(tenant_id, org_name))
            return
        if "UPDATE tenant_settings" in query and "preferred_scan_cadence_hours" in query:
            cadence, alert_email, threshold, tenant_id = args
            row = state.tenant_settings[tenant_id]
            row["preferred_scan_cadence_hours"] = cadence
            row["alert_email"] = alert_email
            row["alert_threshold"] = threshold
            return
        if "UPDATE tenant_settings" in query and "selected_frameworks" in query:
            frameworks, tenant_id = args
            state.tenant_settings[tenant_id]["selected_frameworks"] = frameworks
            return
        if "UPDATE agent_registry" in query and "lifecycle_state" in query:
            lifecycle_state, agent_uuid, tenant_id = args
            for agent in state.agent_registry:
                if agent["id"] == agent_uuid and agent["tenant_id"] == tenant_id:
                    agent["lifecycle_state"] = lifecycle_state
                    agent["last_transition_at"] = "2026-08-02T00:00:00Z"
                    return
            return
        if "UPDATE nhi_discovered_accounts" in query and "'dismissed'" in query:
            account_uuid, tenant_id = args
            account = state.nhi_accounts[str(account_uuid)]
            assert account["tenant_id"] == tenant_id
            account["status"] = "dismissed"
            account["dismissed_by"] = "demo-actor"
            return
        if "UPDATE tenant_api_keys" in query and "revoked_at = now()" in query:
            (tenant_id,) = args
            for key in state.api_keys:
                if key["tenant_id"] == tenant_id and key["revoked_at"] is None:
                    key["revoked_at"] = "2026-08-02T00:00:00Z"
            return
        if "INSERT INTO tenant_api_keys" in query:
            tenant_id, key_hash, prefix_hint, scope, revealed_by_email = args
            assert revealed_by_email, "revealed_by_email is NOT NULL in tenant_api_keys"
            state.api_keys.append(
                {
                    "tenant_id": tenant_id,
                    "key_hash": key_hash,
                    "prefix_hint": prefix_hint,
                    "scope": scope,
                    "revealed_by_email": revealed_by_email,
                    "revoked_at": None,
                },
            )
            return
        if "INSERT INTO tenant_onboarding" in query:
            (tenant_id,) = args
            state.tenant_onboarding.setdefault(
                tenant_id,
                {
                    "tenant_id": tenant_id,
                    "status": "pending",
                    "skipped_at": None,
                    "completed_at": None,
                    "wizard_state": {},
                },
            )
            return
        raise AssertionError(f"unexpected execute: {query}")

    def read_one(self, state: _State, query: str, *args: Any) -> dict[str, Any] | None:
        if "INSERT INTO agent_registry" in query:
            tenant_id, name, display_name, origin, owner = args
            assert display_name, "display_name is NOT NULL in agent_registry"
            row = {
                "id": uuid.uuid4(),
                "tenant_id": tenant_id,
                "name": name,
                "origin": origin,
                "owner": owner,
                "lifecycle_state": "registered",
                "last_transition_at": None,
                "eu_ai_act_risk_class": "limited",
                "model_name": "gpt-5.4-mini",
                "created_at": None,
            }
            state.agent_registry.append(row)
            return row
        # Merge union: the FOR UPDATE stub (stun, feat/supercred-stun-timeline)
        # is matched FIRST because it is the more specific pattern — a
        # "SELECT id, name FROM agent_registry ... FOR UPDATE" would otherwise be
        # swallowed by the startswith() branch below and return the wrong shape.
        if "FROM agent_registry" in query and "FOR UPDATE" in query:
            agent_uuid, tenant_id = args
            for agent in state.agent_registry:
                if agent["id"] == agent_uuid and agent["tenant_id"] == tenant_id:
                    return agent
            return None
        if query.startswith("SELECT id, name FROM agent_registry"):
            agent_id, tenant_id = args
            for row in state.agent_registry:
                if row["id"] == agent_id and row["tenant_id"] == tenant_id:
                    return {"id": row["id"], "name": row["name"]}
            return None
        if "WITH revoked AS (" in query and "UPDATE public.agent_credentials" in query:
            tenant_id, agent_id, revoked_by = args
            tokens_revoked = 0
            for credential in state.agent_credentials:
                if (
                    credential["tenant_id"] == tenant_id
                    and credential["agent_id"] == agent_id
                    and credential["revoked_at"] is None
                ):
                    credential["revoked_at"] = "2026-08-02T00:00:00Z"
                    credential["revoked_by"] = revoked_by
                    tokens_revoked += 1
            return {"tokens_revoked": tokens_revoked}
        if "FROM tenant_settings" in query:
            return state.tenant_settings.get(args[0])
        if "COUNT(*)" in query and "FROM agent_registry" in query:
            return {"cnt": sum(1 for a in state.agent_registry if a["tenant_id"] == args[0])}
        if "FROM consent_events" in query:
            return None
        # The terminal-transition UPDATE carries its own guard (status <> $2) and
        # returns the row only when it actually moved, which is what makes
        # re-skipping idempotent. The fake has to honour that guard or the
        # idempotence path would never be exercised.
        if "UPDATE tenant_onboarding" in query and "RETURNING" in query:
            tenant_id, status, now = args
            row = state.tenant_onboarding[tenant_id]
            if row["status"] == status:
                return None
            row["status"] = status
            row["completed_at" if status == "completed" else "skipped_at"] = now
            return row
        if "FROM tenant_onboarding" in query:
            return state.tenant_onboarding.get(args[0])
        raise AssertionError(f"unexpected fetchrow: {query}")

    def read_many(self, state: _State, query: str, *args: Any) -> list[dict[str, Any]]:
        if "FROM agent_compliance_results" in query:
            return []
        raise AssertionError(f"unexpected fetch: {query}")


def _fresh_tenant_settings(tenant_id: str, org_name: str) -> dict[str, Any]:
    return {
        "tenant_id": tenant_id,
        "org_name": org_name,
        "plan_tier": "enterprise",
        "api_key_status": "active",
        "selected_frameworks": ["eu-ai-act"],
        "consent_accepted_at": None,
        "cookie_preferences": None,
        "preferred_scan_cadence_hours": 24,
        "alert_email": None,
        "alert_threshold": 1,
    }


# ---------------------------------------------------------------------------
# Auth plumbing
# ---------------------------------------------------------------------------

class _ReadyPool:
    async def close(self) -> None:
        pass


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _bearer(subject: str) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


def _with_pool(monkeypatch: pytest.MonkeyPatch, pool: FakePostgres) -> FakePostgres:
    async def _fake_get_pool() -> FakePostgres:
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _fake_get_pool)
    return pool


@pytest.fixture
def healthy(monkeypatch: pytest.MonkeyPatch) -> FakePostgres:
    return _with_pool(monkeypatch, FakePostgres())


@pytest.fixture
def audit_rejects(monkeypatch: pytest.MonkeyPatch) -> FakePostgres:
    """A database whose audit_events CHECK constraint refuses the write."""
    return _with_pool(monkeypatch, FakePostgres(fail_audit=True))


_PREFERENCES = {
    "preferred_scan_cadence_hours": 6,
    "alert_email": "alerts@signalloom.local",
    "alert_threshold": 4,
}


# ---------------------------------------------------------------------------
# Success: the mutation and its audit record commit together
# ---------------------------------------------------------------------------

def test_creating_an_agent_commits_the_row_and_its_audit_event_together(
    client: TestClient, healthy: FakePostgres,
) -> None:
    response = client.post(
        "/api/agents",
        json={"name": "Ledger Agent", "type": "service"},
        headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    assert [a["name"] for a in healthy.committed.agent_registry] == ["Ledger Agent"]
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["agent.created"]
    assert healthy.commits == 1
    assert healthy.rollbacks == 0


def test_patching_preferences_commits_the_write_and_its_audit_event_together(
    client: TestClient, healthy: FakePostgres,
) -> None:
    response = client.patch(
        "/api/tenant/settings/preferences", json=_PREFERENCES, headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    stored = healthy.committed.tenant_settings["tenant-tx-pooled"]
    assert stored["preferred_scan_cadence_hours"] == 6
    assert stored["alert_threshold"] == 4
    assert [e["event_type"] for e in healthy.committed.audit_events] == [
        "tenant.preferences_updated",
    ]
    assert healthy.rollbacks == 0


# ---------------------------------------------------------------------------
# The regression guard: a failing audit insert rolls the business write back
# ---------------------------------------------------------------------------

def test_a_rejected_audit_event_rolls_back_the_preferences_write(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    """The exact production defect: a 500 that had already saved the change.

    Asserted on stored state. That the caller got a 500 was never the bug --
    the bug was that the preferences were in the database anyway.
    """
    response = client.patch(
        "/api/tenant/settings/preferences", json=_PREFERENCES, headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 500, response.text
    assert response.json()["error"]["code"] == "internal_error"

    stored = audit_rejects.committed.tenant_settings.get("tenant-tx-pooled")
    assert stored is None or stored["preferred_scan_cadence_hours"] != 6, (
        "the preferences write survived a failed audit insert"
    )
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.commits == 0
    assert audit_rejects.rollbacks == 1


def test_a_rejected_audit_event_rolls_back_the_agent_row(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    """An agent with no record of its creation is not an agent we can attest to."""
    response = client.post(
        "/api/agents",
        json={"name": "Orphan Agent", "type": "service"},
        headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 500, response.text
    assert audit_rejects.committed.agent_registry == []
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.rollbacks == 1


def _seed_nhi_account(pool: FakePostgres) -> str:
    account_id = str(uuid.uuid4())
    pool.committed.nhi_accounts[account_id] = {
        "id": account_id,
        "tenant_id": "tenant-tx-pooled",
        "status": "needs_triage",
        "dismissed_by": None,
    }
    return account_id


def test_dismissing_an_account_commits_the_status_and_its_audit_event_together(
    client: TestClient, healthy: FakePostgres,
) -> None:
    account_id = _seed_nhi_account(healthy)

    response = client.post(
        f"/api/nhi/discovered/{account_id}/dismiss", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    assert healthy.committed.nhi_accounts[account_id]["status"] == "dismissed"
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["nhi.dismissed"]


def test_a_rejected_audit_event_rolls_back_a_dismissal(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    account_id = _seed_nhi_account(audit_rejects)

    response = client.post(
        f"/api/nhi/discovered/{account_id}/dismiss", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 500, response.text
    account = audit_rejects.committed.nhi_accounts[account_id]
    assert account["status"] == "needs_triage", "the dismissal survived a failed audit insert"
    assert account["dismissed_by"] is None
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.rollbacks == 1


# ---------------------------------------------------------------------------
# stun_agent: the isolation and its record are one write
# ---------------------------------------------------------------------------

# Renamed at merge. feat/supercred-stun-timeline and feat/supercred-inventory-live
# each defined a _seed_registry_agent with an incompatible signature and return
# type (uuid.UUID vs str, and different seeded columns). They do not textually
# overlap, so git merged both definitions cleanly and Python silently kept the
# LAST one — handing the stun tests a helper that rejects their keyword argument.
# Distinct helpers now carry distinct names.
def _seed_stun_agent(pool: FakePostgres, lifecycle_state: str = "active") -> uuid.UUID:
    agent_uuid = uuid.uuid4()
    pool.committed.agent_registry.append(
        {
            "id": agent_uuid,
            "tenant_id": "tenant-tx-pooled",
            "name": "Cardvault Agent",
            "lifecycle_state": lifecycle_state,
            "last_transition_at": None,
        },
    )
    return agent_uuid


def test_stunning_an_agent_commits_the_state_and_its_audit_event_together(
    client: TestClient, healthy: FakePostgres,
) -> None:
    agent_uuid = _seed_stun_agent(healthy)

    response = client.post(
        f"/api/agents/{agent_uuid}/stun",
        json={"reason": "compliance-failure: securityContext not set"},
        headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    assert healthy.committed.agent_registry[0]["lifecycle_state"] == "suspended"
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["agent.stunned"]
    assert healthy.commits == 1
    assert healthy.rollbacks == 0


def test_the_recorded_from_state_is_read_inside_the_transaction(
    client: TestClient, healthy: FakePostgres,
) -> None:
    """A from_state read outside the write could name a state already gone."""
    agent_uuid = _seed_stun_agent(healthy, lifecycle_state="registered")

    client.post(f"/api/agents/{agent_uuid}/stun", headers=_bearer("tx-pooled"))

    detail = json.loads(healthy.committed.audit_events[0]["detail"])
    assert detail["from_state"] == "registered"
    assert detail["to_state"] == "suspended"


def test_a_rejected_audit_event_leaves_the_agent_unstunned(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    """An agent cut off with no record of who cut it off is the worst outcome.

    Worse than the stun not happening: the operator sees a 500, presses again,
    and the cluster state and the evidence disagree either way. So the isolation
    must not survive a failed audit insert.
    """
    agent_uuid = _seed_stun_agent(audit_rejects)

    response = client.post(f"/api/agents/{agent_uuid}/stun", headers=_bearer("tx-pooled"))

    assert response.status_code == 500, response.text
    assert audit_rejects.committed.agent_registry[0]["lifecycle_state"] == "active", (
        "the stun survived a failed audit insert"
    )
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.commits == 0
    assert audit_rejects.rollbacks == 1


def test_stunning_a_pod_with_no_registry_row_still_records_the_event(
    client: TestClient, healthy: FakePostgres,
) -> None:
    """SuperCred agent ids are pod names. The event must not depend on a UUID."""
    response = client.post(
        "/api/agents/agent-cardvault/stun",
        json={"agent_name": "Cardvault Agent"},
        headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["agent.stunned"]
    assert healthy.committed.audit_events[0]["agent_name"] == "Cardvault Agent"
    # No registry row to update, so the audit insert is the whole write -- and
    # it still goes through a transaction rather than an autocommit statement.
    assert healthy.commits == 1


def test_a_pod_name_row_can_still_say_which_agent_it_was_about(
    client: TestClient, healthy: FakePostgres,
) -> None:
    """audit_events.agent_id is a UUID column, so a pod name stores NULL.

    _audit_log inserts ``_try_uuid(agent_id)``, and _try_uuid('agent-cardvault')
    is None. The instructor panel posts exactly that id, so the demo's headline
    event has always written a row whose subject column is empty -- recoverable
    only from agent_name, and only because the browser happened to send one.

    detail.agent_ref carries the caller's identifier verbatim so the row is
    self-describing either way. The column stays a UUID FK: that is the right
    shape for registry agents, and the payload is the right place for an id
    that is not one.
    """
    client.post(
        "/api/agents/agent-cardvault/stun",
        json={"agent_name": "Cardvault Agent"},
        headers=_bearer("tx-pooled"),
    )

    event = healthy.committed.audit_events[0]
    assert event["agent_id"] is None, "a pod name is not a UUID and cannot be stored as one"
    assert json.loads(event["detail"])["agent_ref"] == "agent-cardvault"


def test_a_pod_with_no_registry_row_records_no_transition_it_did_not_make(
    client: TestClient, healthy: FakePostgres,
) -> None:
    """Committing atomically is not the same as committing something true.

    The transaction guarantee above says the row and the state change agree.
    It says nothing about whether the row's *contents* describe reality. Here
    there is no registry row, so the ``UPDATE`` is skipped entirely -- and the
    event still recorded ``from_state: "active"``, ``to_state: "suspended"``.
    Neither state was read and the second was never written.

    An impeccable transaction around a fabricated payload is the failure this
    asserts against: it is precisely the shape that reads as trustworthy.
    """
    client.post(
        "/api/agents/agent-cardvault/stun",
        json={"agent_name": "Cardvault Agent"},
        headers=_bearer("tx-pooled"),
    )

    assert healthy.committed.agent_registry == [], "nothing should have been updated"
    detail = json.loads(healthy.committed.audit_events[0]["detail"])
    assert detail["from_state"] == "unknown"
    assert detail["to_state"] == "unchanged"
    assert detail["requested_state"] == "suspended"
    assert detail["registry_match"] is False


# ---------------------------------------------------------------------------
# onboarding: the terminal transition and its audit are one write
# ---------------------------------------------------------------------------
#
# onboarding.py lives outside api_compat.py and was never covered here, so it
# kept the exact shape migration 007 was written about: an UPDATE against the
# pool, then _audit_log(pool, ...) as a second autocommit statement. The tests
# above pin fifteen writers in api_compat; this file's guarantee simply did not
# reach across the module boundary.
#
# onboarding.py binds `_get_pool` at import (`from api_compat import _get_pool`),
# so patching api_compat alone leaves it pointing at the real one. Both names
# have to move or the test silently exercises nothing.

@pytest.fixture
def onboarding_pool(monkeypatch: pytest.MonkeyPatch, healthy: FakePostgres) -> FakePostgres:
    monkeypatch.setattr(onboarding, "_get_pool", lambda: _async(healthy))
    return healthy


@pytest.fixture
def onboarding_audit_rejects(
    monkeypatch: pytest.MonkeyPatch, audit_rejects: FakePostgres,
) -> FakePostgres:
    monkeypatch.setattr(onboarding, "_get_pool", lambda: _async(audit_rejects))
    return audit_rejects


async def _async(value: Any) -> Any:
    return value


def test_completing_onboarding_commits_the_status_and_its_audit_together(
    client: TestClient, onboarding_pool: FakePostgres,
) -> None:
    response = client.post("/api/onboarding/complete", headers=_bearer("tx-pooled"))

    assert response.status_code == 200, response.text
    assert onboarding_pool.committed.tenant_onboarding["tenant-tx-pooled"]["status"] == "completed"
    assert [e["event_type"] for e in onboarding_pool.committed.audit_events] == [
        "onboarding_completed",
    ]


def test_a_rejected_audit_event_leaves_onboarding_incomplete(
    client: TestClient, onboarding_audit_rejects: FakePostgres,
) -> None:
    """A tenant marked onboarded with no record of when is an unanswerable claim.

    "When did this tenant finish onboarding" is exactly the question the status
    exists to answer, and the audit row is the only durable evidence of the
    transition -- tenant_onboarding keeps the terminal state, not the history.
    Letting the status survive a failed audit insert leaves the product asserting
    a completion it cannot evidence.
    """
    response = client.post("/api/onboarding/complete", headers=_bearer("tx-pooled"))

    assert response.status_code == 500, response.text
    assert onboarding_audit_rejects.committed.tenant_onboarding[
        "tenant-tx-pooled"
    ]["status"] == "pending", "the completion survived a failed audit insert"
    assert onboarding_audit_rejects.committed.audit_events == []
    assert onboarding_audit_rejects.rollbacks == 1


def test_skipping_onboarding_is_covered_by_the_same_guarantee(
    client: TestClient, onboarding_audit_rejects: FakePostgres,
) -> None:
    """Skip and complete are the same code path; both must roll back."""
    client.post("/api/onboarding/skip", headers=_bearer("tx-pooled"))

    assert onboarding_audit_rejects.committed.tenant_onboarding[
        "tenant-tx-pooled"
    ]["status"] == "pending"
    assert onboarding_audit_rejects.committed.audit_events == []


# ---------------------------------------------------------------------------
# rotate_api_key: two mutations plus an audit, all or nothing
# ---------------------------------------------------------------------------

def _seed_live_key(pool: FakePostgres, prefix_hint: str = "sl_live_old") -> None:
    pool.committed.api_keys.append(
        {
            "tenant_id": "tenant-tx-pooled",
            "key_hash": "old-hash",
            "prefix_hint": prefix_hint,
            "revoked_at": None,
        },
    )


def _seed_registry_agent(
    pool: FakePostgres,
    *,
    tenant_id: str = "tenant-tx-pooled",
    name: str = "Credential Agent",
) -> str:
    agent_id = str(uuid.uuid4())
    pool.committed.agent_registry.append(
        {
            "id": uuid.UUID(agent_id),
            "tenant_id": tenant_id,
            "name": name,
            "display_name": name,
            "origin": "service",
            "owner": "ops@signalloom.local",
            "lifecycle_state": "active",
            "last_transition_at": None,
            "eu_ai_act_risk_class": "limited",
            "model_name": "gpt-5.4-mini",
            "created_at": None,
        },
    )
    return agent_id


def test_rotating_a_key_revokes_and_issues_in_one_transaction(
    client: TestClient, healthy: FakePostgres,
) -> None:
    _seed_live_key(healthy)

    response = client.post(
        "/api/tenants/tenant-tx-pooled/api-keys/rotate", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    keys = healthy.committed.api_keys
    assert len(keys) == 2
    assert keys[0]["revoked_at"] is not None, "the previous key must be revoked"
    assert keys[1]["revoked_at"] is None, "the replacement must be live"
    assert keys[1]["prefix_hint"] == response.json()["prefix_hint"]
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["api_key.rotated"]
    assert healthy.commits == 1


def test_a_rejected_audit_event_leaves_the_previous_key_live(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    """Half a rotation is a security state, not merely an inconsistency.

    Revoking without issuing locks the tenant out; issuing without the audit row
    mints a live credential nobody can account for. Neither may survive.
    """
    _seed_live_key(audit_rejects)

    response = client.post(
        "/api/tenants/tenant-tx-pooled/api-keys/rotate", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 500, response.text
    keys = audit_rejects.committed.api_keys
    assert len(keys) == 1, "a replacement key was issued despite the failure"
    assert keys[0]["prefix_hint"] == "sl_live_old"
    assert keys[0]["revoked_at"] is None, "the tenant was locked out by a failed rotation"
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.rollbacks == 1


def test_issuing_a_credential_commits_the_row_and_its_audit_event_together(
    client: TestClient, healthy: FakePostgres,
) -> None:
    agent_id = _seed_registry_agent(healthy)

    response = client.post(
        f"/api/agents/{agent_id}/credentials", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    credentials = healthy.committed.agent_credentials
    assert len(credentials) == 1
    assert credentials[0]["agent_id"] == uuid.UUID(agent_id)
    assert credentials[0]["revoked_at"] is None
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["agent.credential_issued"]
    assert healthy.commits == 1


def test_a_rejected_audit_event_rolls_back_credential_issue(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    agent_id = _seed_registry_agent(audit_rejects)

    response = client.post(
        f"/api/agents/{agent_id}/credentials", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 500, response.text
    assert audit_rejects.committed.agent_credentials == []
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.rollbacks == 1


def test_revoking_credentials_updates_rows_and_audits_in_one_transaction(
    client: TestClient, healthy: FakePostgres,
) -> None:
    agent_id = _seed_registry_agent(healthy)
    issued = client.post(
        f"/api/agents/{agent_id}/credentials", headers=_bearer("tx-pooled"),
    )
    assert issued.status_code == 200, issued.text
    healthy.committed.audit_events.clear()
    healthy.commits = 0

    response = client.post(
        f"/api/agents/{agent_id}/credentials/revoke", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["tokens_revoked"] == 1
    assert healthy.committed.agent_credentials[0]["revoked_at"] is not None
    assert healthy.committed.agent_credentials[0]["revoked_by"] == "demo-actor"
    assert [e["event_type"] for e in healthy.committed.audit_events] == ["agent.credential_revoked"]
    assert healthy.commits == 1


def test_a_rejected_audit_event_rolls_back_credential_revocation(
    client: TestClient, audit_rejects: FakePostgres,
) -> None:
    agent_id = _seed_registry_agent(audit_rejects)
    issued = client.post(
        f"/api/agents/{agent_id}/credentials", headers=_bearer("tx-pooled"),
    )
    assert issued.status_code == 500, issued.text
    audit_rejects.fail_audit = False
    issued = client.post(
        f"/api/agents/{agent_id}/credentials", headers=_bearer("tx-pooled"),
    )
    assert issued.status_code == 200, issued.text
    audit_rejects.committed.audit_events.clear()
    audit_rejects.fail_audit = True

    response = client.post(
        f"/api/agents/{agent_id}/credentials/revoke", headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 500, response.text
    assert audit_rejects.committed.agent_credentials[0]["revoked_at"] is None
    assert audit_rejects.committed.agent_credentials[0]["revoked_by"] is None
    assert audit_rejects.committed.audit_events == []
    assert audit_rejects.rollbacks >= 1


# ---------------------------------------------------------------------------
# The subtle one: the post-write re-read must sit outside the transaction
# ---------------------------------------------------------------------------

def test_the_post_write_re_read_returns_the_committed_values(
    client: TestClient, healthy: FakePostgres,
) -> None:
    """``return await tenant_settings(...)`` acquires its own connection.

    Moved inside the ``_write()`` block it would read through the pool, see
    nothing of the open transaction, and answer with stale values -- a wrong
    body rather than an error, which is why this is asserted on the response
    and not merely on the stored row.
    """
    response = client.patch(
        "/api/tenant/settings/preferences", json=_PREFERENCES, headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["preferred_scan_cadence_hours"] == 6
    assert body["alert_email"] == "alerts@signalloom.local"
    assert body["alert_threshold"] == 4


def test_the_frameworks_re_read_returns_the_committed_values(
    client: TestClient, healthy: FakePostgres,
) -> None:
    response = client.patch(
        "/api/tenant/settings/frameworks",
        json={"selected_frameworks": ["eu-ai-act", "nist-ai-rmf"]},
        headers=_bearer("tx-pooled"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["selected_frameworks"] == ["eu-ai-act", "nist-ai-rmf"]


def test_an_open_transaction_is_invisible_to_a_pool_read(healthy: FakePostgres) -> None:
    """The property the two tests above rely on, asserted directly.

    Without it those tests would pass against a fake that simply applied writes
    as it went, and would therefore prove nothing about where the re-read sits.
    """
    import asyncio

    async def scenario() -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        async with api_compat._write(healthy) as conn:
            await conn.execute(
                "INSERT INTO tenant_settings (tenant_id, org_name) VALUES ($1, $2)",
                "tenant-tx-pooled", "Mid-Transaction Org",
            )
            during = await healthy.fetchrow(
                "SELECT * FROM tenant_settings WHERE tenant_id = $1", "tenant-tx-pooled",
            )
        after = await healthy.fetchrow(
            "SELECT * FROM tenant_settings WHERE tenant_id = $1", "tenant-tx-pooled",
        )
        return during, after

    during, after = asyncio.run(scenario())
    assert during is None, "a pool read saw an uncommitted row"
    assert after is not None and after["org_name"] == "Mid-Transaction Org"


# ---------------------------------------------------------------------------
# The no-pool in-memory path is untouched
# ---------------------------------------------------------------------------

def test_the_in_memory_path_still_writes_and_reads_back_without_a_pool(
    client: TestClient,
) -> None:
    """``_get_pool()`` returns None when Postgres is absent; nothing here changed."""
    patched = client.patch(
        "/api/tenant/settings/preferences", json=_PREFERENCES, headers=_bearer("tx-memory"),
    )
    assert patched.status_code == 200, patched.text

    fetched = client.get("/api/tenant/settings", headers=_bearer("tx-memory"))
    assert fetched.status_code == 200, fetched.text
    body = fetched.json()
    assert body["preferred_scan_cadence_hours"] == 6
    assert body["alert_email"] == "alerts@signalloom.local"
    assert body["alert_threshold"] == 4


def test_the_in_memory_path_still_creates_agents_without_a_pool(client: TestClient) -> None:
    response = client.post(
        "/api/agents",
        json={"name": "Fixture Agent", "type": "service"},
        headers=_bearer("tx-memory"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["name"] == "Fixture Agent"
    assert response.json()["lifecycle_state"] == "registered"


def test_the_in_memory_path_still_rotates_keys_without_a_pool(client: TestClient) -> None:
    response = client.post(
        "/api/tenants/tenant-tx-memory/api-keys/rotate", headers=_bearer("tx-memory"),
    )

    assert response.status_code == 200, response.text
    assert response.json()["key"].startswith("sl_live_tenant-tx-memory_")
    assert response.json()["scope"] == "tenant:read-write"


# ---------------------------------------------------------------------------
# Structural guard: a future multi-write handler cannot skip the transaction
# ---------------------------------------------------------------------------
#
# Derived from the AST rather than restated as a list of handler names, for the
# same reason test_audit_event_types.py derives its vocabulary: a hand-kept list
# goes stale the first time someone adds a handler, and a guard that misses call
# sites is worse than no guard because it reads as coverage.

_MUTATIONS = ("INSERT", "UPDATE", "DELETE")

# A write does not have to be the first keyword in the statement. The revoke
# handler needs the affected-row count in the same round trip, so its UPDATE
# lives inside a CTE:
#
#     WITH revoked AS (UPDATE ... RETURNING 1) SELECT COUNT(*) FROM revoked
#
# A prefix test alone reads that as a plain SELECT and the handler drops out of
# the enumeration entirely -- which is the failure mode this guard exists to
# prevent, arriving through the guard's own blind spot. Matching the keyword
# anywhere in a WITH-prefixed statement closes it. The word boundary keeps a
# column or table merely *named* "update" from registering as one.
_MUTATION_IN_CTE = re.compile(r"\b(INSERT|UPDATE|DELETE)\b", re.IGNORECASE)


def _sql_writes(sql: str) -> bool:
    """True if ``sql`` mutates, whether directly or from inside a CTE."""
    statement = sql.lstrip()
    if statement.upper().startswith(_MUTATIONS):
        return True
    if not statement.upper().startswith("WITH"):
        return False
    return _MUTATION_IN_CTE.search(statement) is not None


def _is_mutating_call(node: ast.Call) -> str | None:
    """Return the receiver name if ``node`` issues a write, else None."""
    func = node.func
    if isinstance(func, ast.Name) and func.id == "_audit_log":
        if node.args and isinstance(node.args[0], ast.Name):
            return node.args[0].id
        return "?"
    if not isinstance(func, ast.Attribute) or func.attr not in {"execute", "fetchrow"}:
        return None
    if not node.args or not isinstance(node.args[0], ast.Constant):
        return None
    if not _sql_writes(str(node.args[0].value)):
        return None
    return func.value.id if isinstance(func.value, ast.Name) else "?"


def _handlers_with_multiple_writes() -> dict[str, list[str]]:
    tree = ast.parse(API_COMPAT.read_text(encoding="utf-8"))
    found: dict[str, list[str]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.AsyncFunctionDef):
            continue
        receivers = [
            receiver
            for child in ast.walk(node)
            if isinstance(child, ast.Call) and (receiver := _is_mutating_call(child))
        ]
        if len(receivers) >= 2:
            found[node.name] = receivers
    return found


def test_the_enumeration_still_finds_the_handlers_it_was_written_against() -> None:
    """If this shrinks to nothing the guard below is vacuous, so say so."""
    assert set(_handlers_with_multiple_writes()) >= {
        "create_agent",
        "issue_agent_credential",
        "transition_agent",
        "revoke_agent_credential",
        "acknowledge_violation",
        "enroll_nhi_account",
        "dismiss_nhi_account",
        "patch_tenant_frameworks",
        "patch_tenant_preferences",
        "create_initial_api_key",
        "rotate_api_key",
        "accept_consent",
        "patch_cookie_preferences",
    }


@pytest.mark.parametrize("handler", sorted(_handlers_with_multiple_writes()))
def test_every_multi_write_handler_writes_through_a_single_connection(handler: str) -> None:
    """Two or more writes in one handler means one transaction, on one ``conn``.

    A statement issued against the pool inside an open ``_write()`` block runs
    on a different connection and silently escapes the transaction, so the
    receiver is checked, not just the presence of the helper.
    """
    receivers = _handlers_with_multiple_writes()[handler]
    assert set(receivers) == {"conn"}, (
        f"{handler} issues writes through {sorted(set(receivers))}; "
        "every statement in a multi-write handler must use the _write() connection"
    )

    source = ast.parse(API_COMPAT.read_text(encoding="utf-8"))
    node = next(
        n for n in ast.walk(source)
        if isinstance(n, ast.AsyncFunctionDef) and n.name == handler
    )
    uses_write = any(
        isinstance(item.context_expr, ast.Call)
        and isinstance(item.context_expr.func, ast.Name)
        and item.context_expr.func.id == "_write"
        for child in ast.walk(node)
        if isinstance(child, ast.AsyncWith)
        for item in child.items
    )
    assert uses_write, f"{handler} performs multiple writes without _write()"
