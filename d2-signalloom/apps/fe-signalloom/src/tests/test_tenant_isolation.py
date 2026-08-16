"""The authorization boundary, pinned per endpoint rather than per sample.

WHY THIS FILE EXISTS
====================

``test_api_compat.test_responses_never_mix_records_between_tenants`` was the
suite's only cross-tenant test.  It samples four LIST routes and asserts that
the string ``"tenant-b"`` does not appear in alice's response text.  Measured,
not assumed, against this base:

    $ ./tests/mutation_probe.sh agent_by_id_tenant_filter tests -q
      mutation applied: SELECT * FROM agent_registry WHERE id = $1 AND tenant_id = $2
                     -> SELECT * FROM agent_registry WHERE id = $1 AND $2 IS NOT NULL
      676 passed, 83 skipped, 40 warnings in 14.94s

Deleting the tenant filter from a by-id read left the entire suite green.  So
did deleting it from the agent list, and from the discovery-account detail
read.  Three reasons compound:

1. It samples LIST routes only.  Nothing addressed an object by id, which is
   where a missing ``AND tenant_id = $2`` actually lives.
2. It is a substring check on the tenant *label*.  The in-memory fixture store
   happens to key ids as ``f"{tenant}:agent-1"``, so the label is embedded in
   every id by luck.  Real rows are UUIDs: tenant B's records would leak
   without the string "tenant-b" appearing anywhere in the response.
3. ``api_compat._get_pool()`` returns ``None`` under TestClient, so it runs
   entirely in fixture mode against a ``dict[tenant][id]`` store.  The store is
   keyed by tenant, so isolation holds there *by data structure* no matter what
   the SQL says.  Every ``WHERE tenant_id`` in the file was untested.

This file tests the mechanism instead of a sample of its effects, and every
test in it is accompanied by the mutation that turns it red.  Run them:

    ./tests/mutation_probe.sh <mutation-id> tests/test_tenant_isolation.py -q

A test here that survives its own mutation is worthless and must be deleted or
repaired -- an authz test that would pass with the control removed is the exact
defect this file was written to catch.
"""
from __future__ import annotations

import base64
import json
import re
import socket
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from types import SimpleNamespace

import api_compat
import onboarding
from api_compat import JWTValidationError, settings, validate_jwt
from db.connection import set_pool_for_testing
from main import app

# ---------------------------------------------------------------------------
# Two tenants.  Always two.
# ---------------------------------------------------------------------------
#
# A single-tenant dataset cannot detect a missing `WHERE tenant_id = $1`: every
# row it can return is the caller's own, so the query is correct and incorrect
# at the same time and the test cannot tell.  Every fixture below seeds both.

ALICE, TENANT_A = "alice", "tenant-a"
BOB, TENANT_B = "bob", "tenant-b"
SUBJECT_TENANTS = {ALICE: TENANT_A, BOB: TENANT_B}

ISSUER = "https://issuer.test/dex"
AUDIENCE = "signalloom-api"
AZP = "signalloom-dashboard"

SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
FOREIGN_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

PUBLIC_KEY_PEM = SIGNING_KEY.public_key().public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)


class _JWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        if jwt.get_unverified_header(token).get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=SIGNING_KEY.public_key())


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _seg(value: dict[str, Any]) -> str:
    return _b64(json.dumps(value, separators=(",", ":")).encode())


def token_for(
    subject: str = ALICE,
    *,
    issuer: str = ISSUER,
    audience: str | list[str] = AUDIENCE,
    azp: str = AZP,
    key_id: str = "test-key",
    signing_key: Any = None,
    algorithm: str = "RS256",
    lifetime: int = 300,
    not_before: int = 0,
    extra_claims: dict[str, Any] | None = None,
) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": issuer,
        "aud": audience,
        "sub": subject,
        "iat": now,
        "nbf": now + not_before,
        "exp": now + lifetime,
        "azp": azp,
    }
    if extra_claims:
        claims.update(extra_claims)
    return jwt.encode(
        claims,
        SIGNING_KEY if signing_key is None else signing_key,
        algorithm=algorithm,
        headers={"kid": key_id, "typ": "JWT"},
    )


def bearer(subject_or_token: str = ALICE) -> dict[str, str]:
    """Header for a subject name, or for an already-minted token string."""
    token = subject_or_token if "." in subject_or_token else token_for(subject_or_token)
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", ISSUER)
    monkeypatch.setattr(settings, "api_jwt_audience", AUDIENCE)
    monkeypatch.setattr(settings, "api_jwt_authorized_party", AZP)
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    # Neither test subject is a superadmin.  The superadmin sweep below mints
    # its own; leaving the default allowlist in place would make every
    # "non-superadmin is refused" assertion depend on alice happening not to be
    # on it, which is a property of config rather than of the gate.
    monkeypatch.setattr(settings, "api_superadmin_emails", set())
    monkeypatch.setattr(settings, "api_superadmin_subjects", set())
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWKClient())

    def no_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in API tests")

    monkeypatch.setattr(socket.socket, "connect", no_network)
    set_pool_for_testing(SimpleNamespace(close=_noop_close))
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


async def _noop_close() -> None:
    return None


# ---------------------------------------------------------------------------
# Tenant-owned tables, read from the migrations rather than hand-listed
# ---------------------------------------------------------------------------
#
# A hand-maintained table list goes stale the first time someone adds a table,
# and goes stale SILENTLY -- the sweep below would simply stop checking the new
# one.  Deriving it from the DDL means a new tenant-scoped table is in scope
# from the migration that creates it.

_MIGRATIONS = __import__("pathlib").Path(__file__).resolve().parent.parent / "db" / "migrations"


def _tenant_owned_tables() -> frozenset[str]:
    ddl = "\n".join(path.read_text() for path in sorted(_MIGRATIONS.glob("*.sql")))
    tables = {
        match.group(1)
        for match in re.finditer(
            r"CREATE TABLE IF NOT EXISTS\s+(?:public\.)?(\w+)\s*\((.*?)\n\);", ddl, re.S
        )
        if re.search(r"^\s*tenant_id\b", match.group(2), re.M)
    }
    return frozenset(tables)


TENANT_OWNED_TABLES = _tenant_owned_tables()


def test_the_tenant_owned_table_list_is_derived_and_non_empty():
    """The sweep's scope must not be able to silently become empty.

    Every assertion below is of the form "if the statement touches a
    tenant-owned table, then ...".  A regex that stopped matching the DDL would
    make that antecedent false everywhere and the whole sweep would pass while
    checking nothing -- vacuous-green, the failure mode this repo has already
    shipped twice.  Assert the mechanism produced something first.
    """
    assert _MIGRATIONS.is_dir(), f"migrations directory missing: {_MIGRATIONS}"
    assert len(TENANT_OWNED_TABLES) >= 15, sorted(TENANT_OWNED_TABLES)
    # Spot-check the two that carry the most sensitive rows, so a regex that
    # matched only trivial tables is still a failure.
    assert {"agent_registry", "audit_events", "tenant_api_keys"} <= TENANT_OWNED_TABLES


# ---------------------------------------------------------------------------
# A pool that records what was asked of the database
# ---------------------------------------------------------------------------


class RecordingPool:
    """Captures every statement and its bound arguments.

    Returns nothing useful on purpose.  The handler may well 500 on the empty
    result -- that is not what is under test.  What is under test is the SQL it
    issued before it got there, because a dropped tenant predicate is visible
    in the statement whether or not the handler goes on to succeed.
    """

    def __init__(self) -> None:
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    def _record(self, query: str, args: tuple[Any, ...]) -> None:
        self.statements.append((query, args))

    async def fetch(self, query: str, *args: Any) -> list[Any]:
        self._record(query, args)
        return []

    async def fetchrow(self, query: str, *args: Any) -> None:
        self._record(query, args)
        return None

    async def fetchval(self, query: str, *args: Any) -> None:
        self._record(query, args)
        return None

    async def execute(self, query: str, *args: Any) -> str:
        self._record(query, args)
        return "OK"

    # _write() acquires a connection and opens a transaction on it.  Both are
    # async context managers and the connection is this same recorder, so a
    # mutation's statements land in the same list as a read's.
    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


_TABLE_REF = re.compile(r"\b(?:FROM|JOIN|INTO|UPDATE)\s+(?:public\.)?(\w+)", re.I)
_TENANT_PREDICATE = re.compile(r"\btenant_id\s*=\s*\$(\d+)", re.I)


def _tables_touched(sql: str) -> set[str]:
    return {name.lower() for name in _TABLE_REF.findall(sql)} & TENANT_OWNED_TABLES


def unscoped_statements(pool: RecordingPool, tenant: str) -> list[tuple[str, tuple[Any, ...]]]:
    """Statements that touch a tenant-owned table without binding this tenant.

    Two ways to be scoped, because the SQL in this module uses both:

    * a ``tenant_id = $N`` predicate whose bound argument is the caller's
      tenant -- SELECT, UPDATE, DELETE;
    * an INSERT that writes the caller's tenant into the row.

    Anything else is reachable across tenants, whatever the handler's parameter
    list claims.
    """
    offenders = []
    for sql, args in pool.statements:
        if not _tables_touched(sql):
            continue
        bound = {index for index, value in enumerate(args, start=1) if value == tenant}
        predicate_positions = {int(m.group(1)) for m in _TENANT_PREDICATE.finditer(sql)}
        if predicate_positions & bound:
            continue
        if sql.lstrip().upper().startswith("INSERT") and bound:
            continue
        offenders.append((sql, args))
    return offenders


# ---------------------------------------------------------------------------
# The sweep: every route that reaches the database, scoped to the caller
# ---------------------------------------------------------------------------
#
# (method, path, json-body-or-None).  Chosen so each request reaches the pool.

DB_ROUTES: list[tuple[str, str, dict[str, Any] | None]] = [
    ("GET", "/api/agents", None),
    ("GET", "/api/agents/00000000-0000-0000-0000-0000000000a1", None),
    ("GET", "/api/agents/00000000-0000-0000-0000-0000000000a1/violations", None),
    ("GET", "/api/audit", None),
    ("GET", "/api/compliance/summary", None),
    ("GET", "/api/compliance/posture", None),
    ("GET", "/api/nhi/scans", None),
    ("GET", "/api/nhi/discovered", None),
    ("GET", "/api/nhi/discovered/00000000-0000-0000-0000-0000000000c1", None),
    ("GET", "/api/nhi/report/json", None),
    ("GET", "/api/tenant/settings", None),
    ("GET", "/api/tenant/users", None),
    ("GET", "/api/user/preferences", None),
    ("GET", "/api/consent/status", None),
    ("GET", "/api/cookie-preferences", None),
    ("GET", "/api/onboarding/status", None),
    ("GET", "/api/onboarding/state", None),
    ("POST", "/api/agents", {"name": "probe", "type": "service"}),
    ("POST", "/api/agents/00000000-0000-0000-0000-0000000000a1/credentials", None),
    ("POST", "/api/agents/00000000-0000-0000-0000-0000000000a1/credentials/revoke", None),
    (
        "POST",
        "/api/agents/00000000-0000-0000-0000-0000000000a1/transition",
        {"to_state": "active", "reason": "probe"},
    ),
    ("POST", "/api/agents/violations/00000000-0000-0000-0000-0000000000b1/acknowledge", None),
    (
        "POST",
        "/api/agents/00000000-0000-0000-0000-0000000000a1/compliance/ctrl-1/reassess",
        None,
    ),
    ("POST", "/api/nhi/discovered/00000000-0000-0000-0000-0000000000c1/enroll", None),
    (
        "POST",
        "/api/nhi/discovered/00000000-0000-0000-0000-0000000000c1/dismiss",
        {"reason": "probe"},
    ),
    ("PATCH", "/api/tenant/settings/frameworks", {"selected_frameworks": ["EU AI Act"]}),
    (
        "PATCH",
        "/api/tenant/settings/preferences",
        {"preferred_scan_cadence_hours": 24, "alert_threshold": 3},
    ),
    ("PATCH", "/api/user/preferences", {"display_currency": "GBP"}),
    ("POST", "/api/support", {"subject": "probe", "urgency": "low", "message": "probe"}),
    ("POST", f"/api/tenants/{TENANT_A}/api-keys/initial", None),
    ("POST", f"/api/tenants/{TENANT_A}/api-keys/rotate", None),
    (
        "POST",
        "/api/consent/accept",
        {
            "document_versions": {"tos": "2026-01"},
            "cookie_preferences": {"strictly_necessary": True, "analytics": False},
            "b2b_warranty_accepted": True,
        },
    ),
    ("PATCH", "/api/cookie-preferences", {"analytics": True}),
    ("POST", "/api/onboarding/skip", None),
    ("POST", "/api/onboarding/complete", None),
    (
        "POST",
        "/api/compliance/policy/scan",
        {"namespace": "probe-ns", "policyVersion": "v1", "frameworks": []},
    ),
]


@pytest.fixture
def recording(monkeypatch):
    pool = RecordingPool()

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    # `onboarding` does `from api_compat import _get_pool`, which binds the
    # function object into its own module namespace at import time. Patching
    # only `api_compat._get_pool` leaves the onboarding routes talking to the
    # real (absent) pool, and they then answer from their fixture fallback --
    # which is a green sweep that never reached a database. Patch both.
    monkeypatch.setattr(onboarding, "_get_pool", get_pool)
    return pool


@pytest.mark.parametrize(
    ("method", "path", "body"),
    DB_ROUTES,
    ids=[f"{method} {path}" for method, path, _ in DB_ROUTES],
)
def test_every_database_statement_is_bound_to_the_callers_tenant(
    client, recording, method, path, body
):
    """No statement may reach a tenant-owned table without the caller's tenant.

    This is the generalisation of
    ``test_tenant_users_reads_only_authenticated_tenant_records``, which
    already had the right shape -- assert the SQL text AND the bound argument --
    but was applied to exactly one of the thirty-odd routes that reach the
    database.

    Deliberately asserts on the statement rather than on the response body.  A
    response-body assertion needs a database that would return another tenant's
    row, which no fixture here has; a statement assertion catches the dropped
    predicate at the point it is written, and catches it on a route whose
    handler goes on to fail for an unrelated reason.

    Falsified by: agent_by_id_tenant_filter, agent_list_tenant_filter,
    audit_tenant_filter, nhi_detail_tenant_filter, violation_ack_tenant_filter.
    """
    response = client.request(method, path, json=body, headers=bearer(ALICE))

    # Authentication must have succeeded, or the route never got far enough to
    # query anything and a green result would mean nothing.
    assert response.status_code not in (401, 403), response.text
    assert recording.statements, (
        f"{method} {path} issued no database statement at all -- this route no "
        "longer exercises the pool, so its entry in DB_ROUTES is now vacuous"
    )

    offenders = unscoped_statements(recording, TENANT_A)
    assert not offenders, "\n".join(
        [f"{method} {path} reached tenant-owned data without binding {TENANT_A!r}:"]
        + [f"  args={args!r}\n  sql={' '.join(sql.split())}" for sql, args in offenders]
    )


def test_the_route_sweep_covers_every_authenticated_api_route(client):
    """A new endpoint cannot join the API without being classified.

    The sweep above is only as good as its inventory.  Without this test, an
    endpoint added next month is simply absent from ``DB_ROUTES`` and is never
    checked -- which is how the existing four-route sample came to be treated
    as coverage in the first place.

    Every ``/api`` route must therefore appear in ``DB_ROUTES`` or in
    ``NOT_DATABASE_BACKED`` with a stated reason.
    """
    registered = {
        (method, route.path)
        for route in app.routes
        if getattr(route, "path", "").startswith("/api")
        for method in getattr(route, "methods", set()) - {"HEAD", "OPTIONS"}
    }
    # DB_ROUTES holds concrete URLs; map them back to their templates.
    swept = {(method, _template_for(path)) for method, path, _ in DB_ROUTES}
    classified = swept | set(NOT_DATABASE_BACKED)

    unclassified = registered - classified
    assert not unclassified, (
        "these API routes are in neither DB_ROUTES nor NOT_DATABASE_BACKED, so "
        "nothing checks their tenant scoping:\n  "
        + "\n  ".join(sorted(f"{m} {p}" for m, p in unclassified))
    )
    # And the reverse: a stale entry naming a route that no longer exists would
    # quietly shrink the sweep.
    stale = classified - registered
    assert not stale, (
        "these entries name routes that no longer exist:\n  "
        + "\n  ".join(sorted(f"{m} {p}" for m, p in stale))
    )


def _template_for(concrete: str) -> str:
    """Map a concrete probe URL back to its route template."""
    return (
        concrete.replace("/00000000-0000-0000-0000-0000000000a1", "/{agent_id}")
        .replace("/00000000-0000-0000-0000-0000000000b1", "/{violation_id}")
        .replace("/00000000-0000-0000-0000-0000000000c1", "/{account_id}")
        .replace("/ctrl-1/reassess", "/{control_id}/reassess")
        .replace(f"/tenants/{TENANT_A}/", "/tenants/{tenant_id_path}/")
    )


#: Routes that legitimately never touch a tenant-owned table, each with the
#: reason.  An entry here is a claim that the route holds no tenant data; if
#: that stops being true the sweep must gain it.
NOT_DATABASE_BACKED: list[tuple[str, str]] = [
    ("GET", "/api/health/crypto"),                       # reads a keys directory
    ("GET", "/api/network-tests"),                       # in-process probe results
    ("POST", "/api/network-tests/scan"),                 # in-process probe results
    ("GET", "/api/trust-topology"),                      # derived from live discovery
    ("GET", "/api/compliance/frameworks"),               # SEE test_compliance_frameworks_*
    ("GET", "/api/compliance/export"),                   # returns a URL, no query
    ("POST", "/api/agents/{agent_id}/stun"),             # cluster call; covered by test_agent_stun
    ("GET", "/api/compliance/policy/frameworks"),        # projection of the two above
    ("GET", "/api/compliance/policy/summary"),           # projection of the two above
    ("PUT", "/api/onboarding/state"),                    # covered by test_onboarding
    # Superadmin-gated, so the sweep's ordinary caller is refused before any
    # statement is issued. Its tenant binding has its own test below.
    ("POST", "/api/audit/privileged-invocations"),
    ("GET", "/api/rbac/clusters"),                       # SEE test_rbac_*
    ("GET", "/api/rbac/clusters/{cluster_id}/correlated"),  # SEE test_rbac_*
    ("GET", "/api/demo/supercred/steps"),                # static step list
    ("GET", "/api/demo/supercred/evidence"),             # subprocess probe
    ("POST", "/api/demo/supercred/runs"),                # superadmin; see sweep below
    ("GET", "/api/demo/supercred/runs/{run_id}"),        # SEE test_demo_run_*
    ("GET", "/api/demo/supercred/runs/{run_id}/log"),    # superadmin; see sweep below
    ("GET", "/api/demo/supercred/runs/{run_id}/stream"),  # superadmin; see sweep below
    ("POST", "/api/demo/supercred/reset"),               # superadmin; see sweep below
    ("GET", "/api/demo/supercred/status"),               # superadmin; see sweep below
]


# ---------------------------------------------------------------------------
# A database that honours exactly the WHERE clause it was given
# ---------------------------------------------------------------------------


class TwoTenantPool:
    """Two tenants' rows, filtered by the predicate the handler actually wrote.

    A faithful fake for one property and one only: a row is returned if the
    statement's own ``tenant_id`` predicate admits it.  Drop the predicate and
    the other tenant's row comes back -- which is precisely what Postgres would
    do, and precisely what the recording pool above cannot show, because it
    holds no rows.

    This exists so at least one cross-tenant leak is demonstrable as an HTTP
    response body rather than as an assertion about SQL text.
    """

    def __init__(self, rows: dict[str, list[dict[str, Any]]]) -> None:
        self.rows = rows

    def _select(self, sql: str, args: tuple[Any, ...]) -> list[dict[str, Any]]:
        tables = {name.lower() for name in _TABLE_REF.findall(sql)}
        candidates = [row for table, rs in self.rows.items() if table in tables for row in rs]

        for match in _TENANT_PREDICATE.finditer(sql):
            wanted = args[int(match.group(1)) - 1]
            candidates = [row for row in candidates if row.get("tenant_id") == wanted]

        for match in re.finditer(r"\bid\s*=\s*\$(\d+)", sql):
            wanted = args[int(match.group(1)) - 1]
            candidates = [row for row in candidates if row.get("id") == wanted]
        return candidates

    async def fetch(self, sql: str, *args: Any) -> list[dict[str, Any]]:
        return self._select(sql, args)

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        found = self._select(sql, args)
        return found[0] if found else None

    async def fetchval(self, sql: str, *args: Any) -> Any:
        row = await self.fetchrow(sql, *args)
        return None if row is None else next(iter(row.values()))

    async def execute(self, sql: str, *args: Any) -> str:
        return "OK"

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


BOB_AGENT_ID = uuid.UUID("00000000-0000-0000-0000-00000000b0b1")
ALICE_AGENT_ID = uuid.UUID("00000000-0000-0000-0000-0000000a11c1")


def _agent_row(agent_id: uuid.UUID, tenant: str, name: str) -> dict[str, Any]:
    return {
        "id": agent_id,
        "tenant_id": tenant,
        "name": name,
        "display_name": name,
        "origin": "service",
        "owner": f"owner@{tenant}.test",
        "lifecycle_state": "active",
        "last_transition_at": None,
        "last_transition_by": None,
        "eu_ai_act_risk_class": "limited",
        "model_name": "gpt-5.4-mini",
        "created_at": None,
    }


@pytest.fixture
def two_tenant_db(monkeypatch):
    pool = TwoTenantPool(
        {
            "agent_registry": [
                _agent_row(ALICE_AGENT_ID, TENANT_A, "Alice Inventory Agent"),
                _agent_row(BOB_AGENT_ID, TENANT_B, "Bob Payroll Agent"),
            ],
        }
    )

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    # _compliance_summary_for_agent issues its own aggregate query; the fake
    # returns no rows for it, so short-circuit to a fixed summary rather than
    # teaching the fake arithmetic it has no business knowing.
    async def summary(_executor, _agent_id):
        return api_compat.ComplianceSummaryInline(
            total_controls=0, passing=0, failing=0, pending=0, posture_score=0
        )

    monkeypatch.setattr(api_compat, "_compliance_summary_for_agent", summary)
    return pool


def test_a_tenant_reads_its_own_agent_through_the_same_fake(client, two_tenant_db):
    """Positive control.

    Without this, the cross-tenant test below could pass because the fake
    returns nothing to anybody -- an isolation test that holds because the
    database is empty proves only that the database is empty.
    """
    response = client.get(f"/api/agents/{ALICE_AGENT_ID}", headers=bearer(ALICE))

    assert response.status_code == 200, response.text
    assert response.json()["name"] == "Alice Inventory Agent"
    assert response.json()["tenant_id"] == TENANT_A


def test_addressing_another_tenants_agent_does_not_return_it(client, two_tenant_db):
    """Tenant A must not receive tenant B's agent row.

    Falsified by: agent_by_id_tenant_filter.  With that mutation this returns
    ``"Bob Payroll Agent"`` and ``owner@tenant-b.test`` with HTTP 200.
    """
    response = client.get(f"/api/agents/{BOB_AGENT_ID}", headers=bearer(ALICE))

    body = response.text
    assert "Bob Payroll Agent" not in body, body
    assert TENANT_B not in body, body
    assert "owner@tenant-b.test" not in body, body


def test_listing_agents_returns_only_the_callers_own(client, two_tenant_db):
    """Falsified by: agent_list_tenant_filter."""
    alice = client.get("/api/agents", headers=bearer(ALICE))
    bob = client.get("/api/agents", headers=bearer(BOB))

    assert alice.status_code == 200, alice.text
    assert bob.status_code == 200, bob.text
    alice_names = {agent["name"] for agent in alice.json()["agents"]}
    bob_names = {agent["name"] for agent in bob.json()["agents"]}

    # Positive control first: each tenant can see its own row, so an empty
    # result cannot be mistaken for isolation.
    assert "Alice Inventory Agent" in alice_names, alice.text
    assert "Bob Payroll Agent" in bob_names, bob.text
    assert "Bob Payroll Agent" not in alice_names
    assert "Alice Inventory Agent" not in bob_names


# ---------------------------------------------------------------------------
# Current behaviour of a by-id read for an object that is not the caller's
# ---------------------------------------------------------------------------


def test_unknown_agent_id_is_answered_with_a_synthesised_agent_not_a_404(client, two_tenant_db):
    """PINNED, NOT ENDORSED -- escalated as a product decision.

    ``get_agent`` answers an id it cannot find by fabricating an agent rather
    than returning 404::

        if row is None:
            return AgentResponse(**_synth_agent(tenant_id, agent_id))

    For isolation this is accidentally sound: an id belonging to another tenant
    and an id belonging to nobody produce identical responses, so the route is
    not an existence oracle.  That is a real property and worth keeping.

    It is also a route that returns HTTP 200 and a plausible agent for input
    the server has never seen, in a product whose output is regulatory
    evidence.  A dashboard cannot distinguish "this agent is registered and
    idle" from "no such agent".  Which of 404, 403 or synthesis is correct is a
    product decision -- this test pins what it does today so the answer changes
    deliberately.
    """
    response = client.get(f"/api/agents/{BOB_AGENT_ID}", headers=bearer(ALICE))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["tenant_id"] == TENANT_A
    assert body["name"].startswith("Synthesized")
    assert body["lifecycle_state"] == "registered"


def test_credential_routes_fail_closed_on_an_id_the_caller_does_not_own(
    client, two_tenant_db
):
    """Credentials do NOT synthesise, and must not start.

    ``_db_agent_for_credentials`` requires a registry row matching both the id
    and the tenant.  Minting a credential for another tenant's agent id would
    be the most serious outcome available on this API, so it gets its own test
    rather than riding on the sweep.

    Falsified by: agent_by_id_tenant_filter is NOT the mutation here -- the
    guard is a separate query; see ``credential_owner_tenant_filter``.
    """
    for path in (
        f"/api/agents/{BOB_AGENT_ID}/credentials",
        f"/api/agents/{BOB_AGENT_ID}/credentials/revoke",
    ):
        response = client.post(path, headers=bearer(ALICE))
        assert response.status_code == 404, f"{path} -> {response.status_code} {response.text}"
        assert response.json()["error"]["code"] == "not_found"
        assert "Bob Payroll Agent" not in response.text

    # Positive control: the same routes succeed for the tenant that owns the
    # agent, so the 404s above are the tenant check firing and not the route
    # being broken for everyone.
    owned = client.post(f"/api/agents/{ALICE_AGENT_ID}/credentials", headers=bearer(ALICE))
    assert owned.status_code == 200, owned.text
    assert owned.json()["name"] == "Alice Inventory Agent"


# ---------------------------------------------------------------------------
# Token forgery -- asserting WHICH check rejected, not merely that one did
# ---------------------------------------------------------------------------
#
# `test_invalid_jwt_security_branches_return_same_safe_error` asserts every bad
# token yields the same opaque 401, which is right for the wire.  It is also
# why it cannot tell a signature rejection from a base64 parse error: a forged
# token that is malformed by accident passes that test while proving nothing
# about the control it was written for.  These call validate_jwt directly and
# assert the reason.


def _reason(token: str) -> str:
    """The check that actually rejected the token, not the message on the wire.

    ``validate_jwt`` raises its specific reasons -- "unsupported JWT header",
    "malformed JWT", "missing JWT key identifier" -- from INSIDE its own ``try``
    block, and ``JWTValidationError`` subclasses ``ValueError``.  The handler at
    the bottom of that block catches ``ValueError`` and re-raises
    ``JWTValidationError("invalid Dex JWT") from exc``.  So every one of those
    specific messages is swallowed and replaced before any caller sees it.

    That is deliberate and correct for the wire -- an opaque failure gives an
    attacker no oracle for which check they tripped.  It also means the message
    cannot be used to assert WHICH control fired, and a test that asserted on it
    would be pinning the outer wrapper for every input alike.  ``__cause__``
    preserves the real one, so that is what these tests read.
    """
    with pytest.raises(JWTValidationError) as caught:
        validate_jwt(token)
    error = caught.value
    cause = error.__cause__
    if isinstance(cause, JWTValidationError):
        return str(cause)
    if cause is not None:
        # A PyJWT exception type IS the mechanism: ExpiredSignatureError and
        # InvalidSignatureError are different controls, and a test that could
        # not tell them apart would accept a token rejected for being stale
        # when what it meant to prove was that the signature is checked.
        return type(cause).__name__
    return str(error)


def _hs256_token(claims: dict[str, Any], secret: bytes) -> str:
    """Mint an HS256 JWT without PyJWT.

    ``jwt.encode`` refuses an asymmetric PEM as an HMAC secret -- it raises
    ``InvalidKeyError`` at ENCODE time -- so the library cannot be used to build
    the very forgery this attack consists of.  Building it by hand is not
    incidental: a test that let PyJWT refuse to construct the token would be
    asserting that the attacker's tooling is polite, not that the server is
    safe.
    """
    import hashlib
    import hmac

    header = _seg({"alg": "HS256", "typ": "JWT", "kid": "test-key"})
    payload = _seg(claims)
    signing_input = f"{header}.{payload}".encode()
    signature = hmac.new(secret, signing_input, hashlib.sha256).digest()
    return f"{header}.{payload}.{_b64(signature)}"


@pytest.fixture
def jwt_env(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", ISSUER)
    monkeypatch.setattr(settings, "api_jwt_audience", AUDIENCE)
    monkeypatch.setattr(settings, "api_jwt_authorized_party", AZP)
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWKClient())


def test_a_well_formed_token_validates_so_the_rejections_below_mean_something(jwt_env):
    """Positive control for the whole forgery block."""
    claims = validate_jwt(token_for(ALICE))
    assert claims["sub"] == ALICE
    assert claims["aud"] == AUDIENCE


def test_alg_none_is_rejected_by_the_algorithm_check_not_by_a_parse_error(jwt_env):
    """``alg: none`` must die on the header allowlist.

    The distinction matters.  A token stripped of its signature is also
    structurally odd, so a naive test sees a 401 and concludes the algorithm
    check works when in fact the token never reached it.  Assert the reason.

    Falsified by: jwt_algorithms (which widens the decode allowlist) does not
    reach this -- the header check at the top of validate_jwt does, and
    removing it changes this message.
    """
    now = int(time.time())
    header = _seg({"alg": "none", "typ": "JWT", "kid": "test-key"})
    payload = _seg(
        {"iss": ISSUER, "aud": AUDIENCE, "azp": AZP, "sub": ALICE, "iat": now, "exp": now + 300}
    )
    # A real alg:none token has an empty third segment.  Give it a non-empty
    # one so it survives the `not all(parts)` check and genuinely arrives at
    # the algorithm test rather than being turned away as malformed.
    assert _reason(f"{header}.{payload}.AA") == "unsupported JWT header"

    # And the empty-signature spelling is refused too, for a different and
    # also correct reason.
    assert _reason(f"{header}.{payload}.") == "malformed JWT"


def test_an_rs256_token_resigned_hs256_with_the_public_key_is_rejected(jwt_env):
    """Algorithm confusion: sign with the verifier's own public key as an HMAC secret.

    The classic bypass.  It must fail, and it must fail because RS256 is the
    only algorithm the header check admits -- not because PyJWT happened to
    dislike the key type, which would leave the API one library upgrade away
    from being exploitable.

    Both spellings of the secret are tried.  Servers differ in whether they
    feed the verifier the PEM text or the DER bytes, and a forgery that guesses
    wrong produces a signature mismatch -- which is a rejection for the WRONG
    reason and would leave this test green against a genuinely vulnerable
    server.
    """
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": ALICE,
        "iat": now,
        "exp": now + 300,
        "azp": AZP,
    }
    der = SIGNING_KEY.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    for label, secret in (("pem", PUBLIC_KEY_PEM), ("der", der)):
        forged = _hs256_token(claims, secret)
        assert jwt.get_unverified_header(forged)["alg"] == "HS256", label
        # The header allowlist, not a signature mismatch. A signature failure
        # would report "invalid Dex JWT" from the decode; this reports the
        # algorithm check, which is the control that actually closes the attack.
        assert _reason(forged) == "unsupported JWT header", label


def test_the_decode_allowlist_is_rs256_only_even_if_the_header_check_is_passed(jwt_env):
    """Defence in depth: ``algorithms=["RS256"]`` is the second gate.

    Asserted as a property of the call rather than by forging a token, because
    the header check above turns every non-RS256 token away before the decode
    is reached -- so no request can reach this gate to exercise it.  It is
    still load-bearing: it is what stops a future header-check change from
    silently widening what is accepted.

    Falsified by: jwt_algorithms.
    """
    source = __import__("inspect").getsource(validate_jwt)
    assert 'algorithms=["RS256"]' in source, (
        "validate_jwt no longer pins the decode algorithm allowlist to RS256 alone"
    )


@pytest.mark.parametrize(
    ("make_token", "expected"),
    [
        pytest.param(lambda: token_for(lifetime=-10), "ExpiredSignatureError", id="expired-exp"),
        pytest.param(
            lambda: token_for(not_before=3600), "ImmatureSignatureError", id="future-nbf"
        ),
        pytest.param(
            lambda: token_for(audience="other-api"), "InvalidAudienceError", id="wrong-aud"
        ),
        pytest.param(
            lambda: token_for(issuer="https://attacker.test/dex"),
            "InvalidIssuerError",
            id="wrong-iss",
        ),
        pytest.param(
            lambda: token_for(signing_key=FOREIGN_KEY),
            "InvalidSignatureError",
            id="foreign-signature",
        ),
        pytest.param(
            lambda: token_for(azp="attacker-app"),
            "unexpected JWT authorized party",
            id="wrong-azp",
        ),
        pytest.param(
            lambda: token_for(key_id="unknown-key"), "PyJWKClientError", id="unknown-kid"
        ),
        pytest.param(lambda: _drop_claim("exp"), "MissingRequiredClaimError", id="missing-exp"),
        pytest.param(lambda: _drop_claim("iat"), "MissingRequiredClaimError", id="missing-iat"),
        pytest.param(lambda: _drop_claim("sub"), "MissingRequiredClaimError", id="missing-sub"),
    ],
)
def test_each_claim_forgery_is_refused_by_the_check_it_targets(jwt_env, make_token, expected):
    """Each forgery must trip the specific control it was built to defeat.

    ``test_invalid_jwt_security_branches_return_same_safe_error`` already covers
    the wire behaviour -- an identical opaque 401 for all of these, which is
    right.  What it cannot show is that an expired token is refused for being
    expired rather than for some incidental malformation, and that distinction
    is the difference between a working control and a coincidence.

    Falsified by: jwt_audience (wrong-aud), jwt_issuer (wrong-iss),
    jwt_azp (wrong-azp).
    """
    assert _reason(make_token()) == expected


def _drop_claim(name: str) -> str:
    """A token valid in every respect except that one required claim is absent."""
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": ALICE,
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "azp": AZP,
    }
    claims.pop(name)
    return jwt.encode(
        claims, SIGNING_KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"}
    )


def test_every_rejection_looks_identical_on_the_wire(client):
    """The reasons above must not be observable by a caller.

    The mechanism assertions in this block read ``__cause__`` precisely because
    the message never reaches the wire.  This is the other half of that claim:
    no forgery may produce a distinguishable response, or the endpoint becomes
    an oracle telling an attacker which check to work around next.
    """
    forgeries = [
        token_for(lifetime=-10),
        token_for(not_before=3600),
        token_for(audience="other-api"),
        token_for(issuer="https://attacker.test/dex"),
        token_for(signing_key=FOREIGN_KEY),
        token_for(azp="attacker-app"),
        token_for(key_id="unknown-key"),
        _drop_claim("sub"),
        _hs256_token({"sub": ALICE, "exp": int(time.time()) + 300}, PUBLIC_KEY_PEM),
    ]
    seen = {
        (response.status_code, response.text)
        for response in (
            client.get("/api/agents", headers={"Authorization": f"Bearer {token}"})
            for token in forgeries
        )
    }

    assert len(seen) == 1, seen
    status, text = seen.pop()
    assert status == 401
    assert json.loads(text) == {
        "error": {"code": "invalid_token", "message": "Bearer token is invalid"}
    }


def test_aud_is_verified_and_a_dashboard_audienced_token_cannot_reach_the_api(jwt_env, client):
    """The audience check has already bitten here once, so pin it both ways.

    A token minted for ``signalloom-dashboard`` was rejected by the API on all
    thirty-four endpoints.  That was the control working.  This asserts it is
    still there -- at the claim level with the reason, and at the wire level
    with the response.

    Falsified by: jwt_audience.
    """
    dashboard_token = token_for(ALICE, audience="signalloom-dashboard")

    # The audience check specifically, not merely some rejection: a token
    # audienced to the dashboard is otherwise entirely valid, so anything but
    # InvalidAudienceError would mean it tripped a different control and this
    # one is untested.
    assert _reason(dashboard_token) == "InvalidAudienceError"

    response = client.get("/api/agents", headers={"Authorization": f"Bearer {dashboard_token}"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_token"

    # A multi-audience token that DOES include the API is accepted, so the
    # assertion above is about the audience value and not about aud lists.
    both = token_for(ALICE, audience=["signalloom-dashboard", AUDIENCE])
    assert validate_jwt(both)["sub"] == ALICE


def test_a_tenant_claim_in_the_token_is_never_the_authorisation_decision(client):
    """Client-asserted tenant, role and superadmin claims must all be inert.

    ``authenticated_principal`` derives the tenant from a server-side
    ``api_subject_tenants`` map keyed on ``sub``, so a claim in the token is
    decoration.  The existing suite checks the ``tenant_id`` claim; this adds
    the spellings an attacker would actually try, including the ones the
    dashboard uses for its client-side visibility flag.

    Falsified by: subject_tenant_map.
    """
    forged = token_for(
        ALICE,
        extra_claims={
            "tenant_id": TENANT_B,
            "tenant": TENANT_B,
            "tid": TENANT_B,
            "org": TENANT_B,
            "groups": [TENANT_B, "superadmin"],
            "roles": ["superadmin", "tenant_admin"],
            "role": "superadmin",
            "is_superadmin": True,
            "superadmin": True,
            "scope": "tenant:read-write superadmin",
        },
    )

    settings_response = client.get("/api/tenant/settings", headers=bearer(forged))
    assert settings_response.status_code == 200, settings_response.text
    assert settings_response.json()["tenant_id"] == TENANT_A
    assert TENANT_B not in settings_response.text

    # The same token must not have bought superadmin either.
    privileged = client.post("/api/demo/supercred/reset", headers=bearer(forged))
    assert privileged.status_code == 403, privileged.text
    assert privileged.json()["error"]["code"] == "superadmin_required"


def test_an_unmapped_subject_is_refused_rather_than_defaulted(client):
    """A subject with no entry in the map gets no tenant at all.

    The dangerous alternative is a default: ``get(sub, "tenant-demo")`` would
    hand every valid Dex identity in the estate the demo tenant's data, and
    would look exactly like working software.

    Falsified by: subject_tenant_map.
    """
    response = client.get("/api/agents", headers=bearer(token_for("mallory")))

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "tenant_forbidden"
    assert "mallory" not in response.text
    assert "tenant" not in response.json()["error"]["message"].lower().replace(
        "tenant access", ""
    )


# ---------------------------------------------------------------------------
# Privilege escalation
# ---------------------------------------------------------------------------

SUPERADMIN_ROUTES: list[tuple[str, str, dict[str, Any] | None]] = [
    ("POST", "/api/demo/supercred/runs", {"step": "1"}),
    ("POST", "/api/demo/supercred/reset", None),
    ("GET", "/api/demo/supercred/status", None),
    ("GET", "/api/demo/supercred/runs/any-run-id/log", None),
    ("GET", "/api/demo/supercred/runs/any-run-id/stream", None),
    ("POST", "/api/audit/privileged-invocations", {"step_id": "1", "kind": "step"}),
]


def test_the_privileged_invocation_sink_writes_the_callers_own_tenant(
    client, recording, monkeypatch
):
    """The runner's audit sink must file the row under the validated identity.

    This endpoint is the one place in the API where a *reporter* describes an
    act it performed elsewhere, so the row's tenant has to come from the token
    this process validated and not from anything on the wire.  The request
    model forbids extra fields for that reason; this checks the resulting
    statement.

    Falsified by: any change that takes the tenant from the body.
    """
    monkeypatch.setattr(settings, "api_superadmin_subjects", {ALICE})

    response = client.post(
        "/api/audit/privileged-invocations",
        json={"step_id": "1", "kind": "step"},
        headers=bearer(ALICE),
    )

    assert response.status_code in (200, 201), response.text
    assert recording.statements, "the sink wrote nothing"
    assert not unscoped_statements(recording, TENANT_A)
    inserts = [args for sql, args in recording.statements if "INSERT INTO audit_events" in sql]
    assert inserts, recording.statements
    assert TENANT_A in inserts[0]
    assert TENANT_B not in [arg for arg in inserts[0] if isinstance(arg, str)]


@pytest.mark.parametrize(
    ("method", "path", "body"),
    SUPERADMIN_ROUTES,
    ids=[f"{m} {p}" for m, p, _ in SUPERADMIN_ROUTES],
)
def test_privileged_routes_refuse_an_ordinary_authenticated_caller(client, method, path, body):
    """Every superadmin-gated route, with a valid non-superadmin token.

    Falsified by: superadmin_gate.
    """
    response = client.request(method, path, json=body, headers=bearer(ALICE))

    assert response.status_code == 403, f"{method} {path} -> {response.status_code}"
    assert response.json()["error"]["code"] == "superadmin_required"


@pytest.mark.parametrize(
    ("method", "path", "body"),
    SUPERADMIN_ROUTES,
    ids=[f"{m} {p}" for m, p, _ in SUPERADMIN_ROUTES],
)
def test_privileged_routes_get_past_the_gate_for_a_real_superadmin(
    client, monkeypatch, method, path, body
):
    """Positive control for the sweep above.

    Without it, ``superadmin_required`` on every route would also be the
    result if the gate had become "deny everyone", and the sweep would be
    green while the feature was dead.
    """
    monkeypatch.setattr(settings, "api_superadmin_subjects", {ALICE})

    response = client.request(method, path, json=body, headers=bearer(ALICE))

    assert response.status_code != 403, response.text
    assert "superadmin_required" not in response.text


def test_superadmin_is_decided_from_the_token_identity_not_from_the_request(client, monkeypatch):
    """Nothing client-authored may promote a caller.

    An audit actor read from the request body was already a real defect in this
    codebase, and ``tests/test_audit_provenance.py`` is the static guard
    against its return.  The same reasoning applies to the authorization
    decision: the body, the query string and the headers are all attacker
    controlled.

    Falsified by: superadmin_gate.
    """
    attempts = [
        ("json", {"step": "1", "superadmin": True}),
        ("json", {"step": "1", "actor": "demo-user@signalloom.local"}),
        ("params", {"superadmin": "true"}),
        ("headers", {"X-Superadmin": "true", "X-Roles": "superadmin"}),
        ("headers", {"X-Forwarded-User": "demo-user@signalloom.local"}),
    ]
    for kind, value in attempts:
        kwargs: dict[str, Any] = {"json": {"step": "1"}, "headers": dict(bearer(ALICE))}
        if kind == "json":
            kwargs["json"] = value
        elif kind == "params":
            kwargs["params"] = value
        else:
            kwargs["headers"].update(value)

        response = client.post("/api/demo/supercred/runs", **kwargs)
        assert response.status_code in (403, 422), f"{kind}={value} -> {response.text}"
        if response.status_code == 403:
            assert response.json()["error"]["code"] == "superadmin_required"


# ---------------------------------------------------------------------------
# FINDINGS -- current behaviour pinned, correct behaviour escalated
# ---------------------------------------------------------------------------


def test_api_key_routes_ignore_the_tenant_named_in_their_own_path(client, recording):
    """FINDING: ``{tenant_id_path}`` is unvalidated and flows into key material.

    ``POST /api/tenants/{tenant_id_path}/api-keys/initial`` and ``/rotate``
    both open with::

        tenant_id = principal.tenant
        key = f"sl_live_{tenant_id_path}_{secrets.token_urlsafe(18)}"

    The path segment is never compared with the caller's tenant.  Storage is
    correctly scoped -- every statement binds ``principal.tenant`` -- so this is
    NOT a cross-tenant write.  What it is:

    * the returned key is labelled with a tenant the caller does not own, and
      ``prefix_hint`` -- the first fourteen characters -- is derived from that
      label and persisted to ``tenant_api_keys.prefix_hint`` AND written into
      the ``api_key.created`` audit row.  A tenant A key is filed under a
      prefix that names tenant B, in the evidence trail;
    * a route parameter that names a tenant and is silently ignored is an
      authorization check that reads as present and is absent.

    Correct behaviour is a product decision -- 403 on mismatch, or drop the
    parameter from the route entirely -- so this pins today's behaviour rather
    than choosing.  Escalated.
    """
    # A tenant name the caller chose, distinct enough to be unmistakable in the
    # key material.  "tenant-b" would truncate to the same 14-character prefix
    # hint as "tenant-a" and hide the finding.
    victim = "victimcorp"
    response = client.post(f"/api/tenants/{victim}/api-keys/initial", headers=bearer(ALICE))

    assert response.status_code == 200, response.text
    body = response.json()

    # The caller is tenant-a.  The key it was handed announces victimcorp.
    assert body["key"].startswith(f"sl_live_{victim}_"), body["key"]
    assert body["prefix_hint"] == f"sl_live_{victim}"[:14] == "sl_live_victim", body["prefix_hint"]

    # ... while every statement is correctly bound to the caller's own tenant,
    # which is what keeps this a labelling defect rather than a write leak.
    assert not unscoped_statements(recording, TENANT_A)
    assert all(
        victim != arg for _sql, args in recording.statements for arg in args
    ), recording.statements

    # And the attacker-chosen label reaches persistence, not just the response:
    # it is written to tenant_api_keys.prefix_hint AND into the audit detail.
    persisted = [
        args for sql, args in recording.statements if "INSERT INTO tenant_api_keys" in sql
    ]
    assert persisted, recording.statements
    assert "sl_live_victim" in persisted[0], persisted[0]

    audited = [args for sql, args in recording.statements if "INSERT INTO audit_events" in sql]
    assert audited, recording.statements
    assert any("sl_live_victim" in str(arg) for arg in audited[0]), audited[0]


class GovernancePool(RecordingPool):
    """Records like RecordingPool, but returns one framework so the control
    read actually executes.  With an empty framework list the per-framework
    loop never runs and the second unfiltered statement is never issued --
    which would make the assertion about it pass vacuously."""

    async def fetch(self, query: str, *args: Any) -> list[Any]:
        self._record(query, args)
        if "governance_frameworks" in query:
            return [
                {
                    "id": uuid.UUID("00000000-0000-0000-0000-00000000f001"),
                    "tenant_id": TENANT_B,
                    "name": "Tenant B Bespoke Framework",
                    "version": "1.0",
                    "regulatory_body": "Internal",
                    "compliance_deadline": None,
                    "control_count": 1,
                }
            ]
        return []


def test_compliance_frameworks_reads_governance_tables_without_a_tenant_filter(
    client, monkeypatch
):
    """FINDING: the framework catalogue is read across all tenants.

    ``governance_frameworks`` and ``governance_controls`` both declare
    ``tenant_id TEXT NOT NULL DEFAULT 'tenant-demo'`` in migration 004, so the
    schema author treated them as tenant-owned.  ``GET /compliance/frameworks``
    reads them as global reference data::

        SELECT * FROM governance_frameworks ORDER BY name
        SELECT * FROM governance_controls WHERE framework_id = $1 ORDER BY control_order

    Neither statement mentions the caller's tenant.  A tenant therefore sees
    every other tenant's activated frameworks, their versions, their
    ``compliance_deadline`` and their ``activated_by`` -- which is an email
    address.

    This is not a judgement call about whether the tables are reference data,
    because the same module answers the question in the other direction.
    ``_db_policy_scan``, thirty lines away, reads the SAME two tables with::

        WHERE r.tenant_id = $1 AND c.tenant_id = $1 AND f.tenant_id = $1

    One of the two is wrong.  The filtered one matches the schema.

    Pinned as current behaviour and escalated rather than fixed here: adding
    the filter changes what the dashboard's framework picker shows on a
    seeded estate, which is a product call.
    """
    pool = GovernancePool()

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    response = client.get("/api/compliance/frameworks", headers=bearer(ALICE))

    assert response.status_code == 200, response.text
    offenders = unscoped_statements(pool, TENANT_A)
    offending_sql = [" ".join(sql.split()) for sql, _ in offenders]

    assert "SELECT * FROM governance_frameworks ORDER BY name" in offending_sql, offending_sql
    # The control read is scoped to a framework id, but that id came from the
    # unscoped list above, so it inherits the leak rather than containing it.
    assert any("FROM governance_controls" in sql for sql in offending_sql), offending_sql

    # The leak is observable in the response body, not merely in the SQL: a
    # framework belonging to tenant-b is rendered to tenant-a.
    assert response.json()[0]["name"] == "Tenant B Bespoke Framework", response.text


def test_the_policy_scan_path_does_filter_the_same_governance_tables(client, recording):
    """The in-repo control for the finding above.

    If this test ever fails, the two paths have converged and the finding is
    either fixed or has spread; either way the comparison in
    ``test_compliance_frameworks_reads_governance_tables_without_a_tenant_filter``
    needs rewriting rather than deleting.
    """
    response = client.post(
        "/api/compliance/policy/scan",
        json={"namespace": "probe-ns", "policyVersion": "v1", "frameworks": []},
        headers=bearer(ALICE),
    )
    assert response.status_code == 200, response.text

    governance = [
        " ".join(sql.split())
        for sql, _ in recording.statements
        if "governance_controls" in sql or "governance_frameworks" in sql
    ]
    assert governance, recording.statements
    for sql in governance:
        assert "c.tenant_id = $1" in sql, sql
        assert "f.tenant_id = $1" in sql, sql


def test_rbac_correlation_routes_are_not_tenant_scoped_at_all(client, monkeypatch):
    """FINDING: cluster RBAC is addressable by id, by any authenticated tenant.

    ``/api/rbac/clusters`` and ``/api/rbac/clusters/{cluster_id}/correlated``
    both take ``tenant_id: Annotated[str, Depends(authenticated_tenant)]`` and
    then never mention it again.  The upstream call is built straight from the
    path::

        rbac_raw = await _afm_get_json(client, f"/clusters/{cluster_id}/rbac")

    So the dependency provides authentication and the appearance of
    authorization while providing none: any authenticated caller can name any
    cluster id and read its RBAC graph, its Z3 analysis and its shared-role
    findings.  ``/clusters`` likewise returns everything KubeSec-AFM knows,
    unfiltered.

    Kubernetes RBAC posture is the most sensitive payload this API carries, so
    this is reported loudly rather than pinned quietly.  It is not fixed here:
    the tenant-to-cluster mapping does not exist anywhere in this service --
    there is no table, no config key, and no claim that carries it -- so a
    filter cannot be written without a product decision about where that
    mapping lives.  Escalated.
    """
    captured: list[str] = []

    async def fake_afm(_client, path: str):
        captured.append(path)
        if path == "/clusters":
            return [{"id": "tenant-b-prod-cluster", "name": "Tenant B Production"}]
        if path.endswith("/rbac"):
            return {"subjects": [], "roles": [], "bindings": []}
        return {}

    monkeypatch.setattr("rbac_correlation._afm_get_json", fake_afm)

    listed = client.get("/api/rbac/clusters", headers=bearer(ALICE))
    assert listed.status_code == 200, listed.text
    # tenant-a is shown a cluster that is named for tenant-b, because nothing
    # filters the upstream list.
    assert listed.json() == [{"id": "tenant-b-prod-cluster", "name": "Tenant B Production"}]

    correlated = client.get(
        "/api/rbac/clusters/tenant-b-prod-cluster/correlated", headers=bearer(ALICE)
    )
    assert correlated.status_code == 200, correlated.text

    # The caller's tenant reached neither upstream request.
    assert "/clusters/tenant-b-prod-cluster/rbac" in captured
    assert not any(TENANT_A in path for path in captured), captured


def test_demo_runs_are_a_global_singleton_readable_by_every_tenant(client, monkeypatch):
    """PINNED: ``GET /runs/{run_id}`` discards the tenant it just resolved.

    ``del tenant_id`` is explicit in the handler, and the run store is a
    module-level dict with no tenant dimension.  For a single-cluster demo
    runner that is arguably the intended design -- there is one cluster and one
    run at a time -- but it means a run started by one tenant's superadmin is
    readable by any authenticated user of any tenant.

    Pinned so that the day the runner becomes multi-tenant, this test is the
    thing that fails.
    """
    source = __import__("inspect").getsource(
        __import__("demo_runner").get_demo_run
    )
    assert "del tenant_id" in source, (
        "get_demo_run no longer discards the tenant -- if it now scopes runs by "
        "tenant this test should assert that instead of pinning the old shape"
    )

    response = client.get("/api/demo/supercred/runs/no-such-run", headers=bearer(BOB))
    # Not 403: the route does not consider whose run it is, only whether it
    # exists.  A tenant-scoped route would answer identically for "another
    # tenant's run" and "no run", which this one cannot do because it never
    # asks.
    assert response.status_code == 404, response.text
