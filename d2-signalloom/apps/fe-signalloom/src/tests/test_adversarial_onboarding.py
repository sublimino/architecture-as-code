"""Adversarial boundary tests for onboarding, agent claim, and Nono audit ingest.

SLON-P3-2.  Every test here is an attack, and every attack is expected to fail.

WHY THIS FILE EXISTS, AND WHY IT IS SHAPED THE WAY IT IS
========================================================

Two properties of this service make the *obvious* adversarial test worthless,
and both were measured rather than assumed.

1. ``api_compat._get_pool()`` returns ``None`` under ``TestClient``, so every
   route runs its in-memory fixture branch.  That store is ``dict[tenant][id]``
   -- isolation holds there *by data structure* regardless of what the SQL
   says.  On base ``675772a``, replacing ``WHERE id = $1 AND tenant_id = $2``
   with ``WHERE id = $1 AND $2 IS NOT NULL`` in six queries left the whole
   suite green at ``676 passed, 83 skipped``.  A cross-tenant test that runs on
   the fixture path is therefore not evidence of anything.

2. ``onboarding.py`` and ``audit_ingest.py`` both do
   ``from api_compat import _get_pool``, which binds the name at import time.
   Patching ``api_compat._get_pool`` alone leaves both modules on the fixture
   path while the test believes it is driving a database.  ``_patch_pool``
   below patches all three bindings; ``test_pool_patch_reaches_all_three_modules``
   fails if a fourth importer appears.

So the tests that matter here drive one of two fakes:

* ``RecordingPool`` -- captures every statement and its bound arguments, and
  the assertion is over the SQL that was issued.  A dropped tenant predicate is
  visible in the statement whether or not the handler goes on to succeed.
* ``PredicatePool`` -- holds two tenants' rows and honours exactly the
  ``WHERE`` clause the handler wrote, the way Postgres would.  Drop the
  predicate and the other tenant's row comes back as an HTTP response body.

FALSIFICATION
=============

An authorization test that would pass with its control removed is the precise
defect this repo keeps producing.  Every SQL-level assertion below names the
mutation that turns it red, and those mutations are registered in
``tests/mutation_probe.sh``::

    ./tests/mutation_probe.sh onboarding_terminal_tenant_filter \\
        tests/test_adversarial_onboarding.py -q
    ./tests/mutation_probe.sh onboarding_wizard_write_tenant_filter \\
        tests/test_adversarial_onboarding.py -q
    ./tests/mutation_probe.sh subject_tenant_map \\
        tests/test_adversarial_onboarding.py -q

POSITIVE CONTROLS
=================

A suite of nothing but rejections passes trivially against a service that
rejects everything.  Each rejection group is therefore paired with a positive
control -- a valid token that gets 200, a well-formed session that gets 201, a
same-tenant re-claim that does not 409 -- so "everything is refused" cannot
masquerade as "the boundary holds".

ON THE CARD'S "HTTP 403 ON TENANT MISMATCH"
===========================================

There is no tenant parameter to mismatch.  ``authenticated_tenant`` resolves
the tenant from ``settings.api_subject_tenants[claims["sub"]]`` -- server-side
config -- and no route in any of the three surfaces accepts a tenant identifier
from the caller.  ``test_no_route_accepts_a_caller_supplied_tenant`` proves that
by walking the route table.  403 ``tenant_forbidden`` does exist and fires on a
subject with no tenant mapping; that is asserted directly.  For the IDOR cases
the assertion is the stronger one: a caller-supplied tenant identifier is never
honoured, whether it arrives as a JWT claim or as a request-body field.
"""
from __future__ import annotations

import base64
import hashlib
import inspect
import json
import re
import socket
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from fastapi.testclient import TestClient

import api_compat
import audit_ingest
import demo_runner
import onboarding
from api_compat import settings, reset_tenant_state
from audit_ingest import compute_expected_entry_hash
from db.connection import set_pool_for_testing
from main import app

# ---------------------------------------------------------------------------
# Identities.  Always two tenants, plus one subject with no tenant at all.
# ---------------------------------------------------------------------------

SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ATTACKER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ISSUER = "https://issuer.test/dex"
AUDIENCE = "signalloom-api"
AZP = "signalloom-dashboard"

ALICE = "alice-adv"
BOB = "bob-adv"
MALLORY = "mallory-adv"  # authenticates, but maps to no tenant

TENANT_A = "tenant-adv-a"
TENANT_B = "tenant-adv-b"

SUBJECT_TENANTS = {ALICE: TENANT_A, BOB: TENANT_B}

GENESIS = "0" * 64


class _JWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        if jwt.get_unverified_header(token).get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=SIGNING_KEY.public_key())


def token_for(
    subject: str = ALICE,
    *,
    issuer: str = ISSUER,
    audience: str = AUDIENCE,
    azp: str = AZP,
    key_id: str = "test-key",
    signing_key: Any = None,
    algorithm: str = "RS256",
    lifetime: int = 300,
    extra_claims: dict[str, Any] | None = None,
) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": issuer,
        "aud": audience,
        "sub": subject,
        "iat": now,
        "nbf": now,
        "exp": now + lifetime,
        "azp": azp,
        "email": f"{subject}@corp.test",
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
    token = subject_or_token if "." in subject_or_token else token_for(subject_or_token)
    return {"Authorization": f"Bearer {token}"}


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def unsigned_alg_none_token(subject: str = ALICE) -> str:
    """A token asserting ``alg: none`` with an empty signature segment.

    Hand-assembled: PyJWT refuses to mint one without an explicit opt-in, and
    an attacker has no such scruples.
    """
    now = int(time.time())
    header = _b64u(json.dumps({"alg": "none", "typ": "JWT", "kid": "test-key"}).encode())
    payload = _b64u(
        json.dumps(
            {
                "iss": ISSUER,
                "aud": AUDIENCE,
                "sub": subject,
                "iat": now,
                "nbf": now,
                "exp": now + 300,
                "azp": AZP,
            }
        ).encode()
    )
    return f"{header}.{payload}."


def hs256_confusion_token(subject: str = ALICE) -> str:
    """RS256→HS256 algorithm confusion: the RSA *public* key used as an HMAC secret.

    Hand-assembled with ``hmac`` rather than ``jwt.encode``.  PyJWT refuses to
    mint this -- ``InvalidKeyError: The specified key is an asymmetric key ...
    and should not be used as an HMAC secret`` -- which is a guard on the
    *minting* side only.  An attacker is not using PyJWT to build the token, so
    a test that relies on PyJWT's refusal is testing the test, not the service.
    """
    import hmac

    now = int(time.time())
    public_pem = SIGNING_KEY.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    header = _b64u(json.dumps({"alg": "HS256", "typ": "JWT", "kid": "test-key"}).encode())
    payload = _b64u(
        json.dumps(
            {
                "iss": ISSUER,
                "aud": AUDIENCE,
                "sub": subject,
                "iat": now,
                "nbf": now,
                "exp": now + 300,
                "azp": AZP,
            }
        ).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    signature = hmac.new(public_pem, signing_input, hashlib.sha256).digest()
    return f"{header}.{payload}.{_b64u(signature)}"


# ---------------------------------------------------------------------------
# Fakes for the database.  See the module docstring for why these are required.
# ---------------------------------------------------------------------------

_TABLE_REF = re.compile(r"\b(?:FROM|JOIN|INTO|UPDATE)\s+(?:public\.)?(\w+)", re.I)
_TENANT_EQ = re.compile(r"\btenant_id\s*=\s*\$(\d+)", re.I)
_ID_EQ = re.compile(r"\b(\w+)\s*=\s*\$(\d+)", re.I)
_NEQ = re.compile(r"\b(\w+)\s*<>\s*\$(\d+)", re.I)
_SET_ASSIGN = re.compile(r"(\w+)\s*=\s*\$(\d+)(?:::\w+)?")

# Tables whose rows belong to exactly one tenant.  A statement that touches one
# of these without binding the caller's tenant is reachable across tenants.
TENANT_OWNED_TABLES = {
    "tenant_onboarding",
    "tenant_settings",
    "audit_events",
    "agent_claims",
    "agent_registry",
    "signed_audit_sessions",
    "agent_origin_verifications",
}


class RecordingPool:
    """Captures every statement and its bound arguments.

    Returns nothing useful on purpose.  The handler may well fail on the empty
    result; that is not what is under test.  What is under test is the SQL it
    issued on the way there.
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

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


class PredicatePool:
    """Two tenants' rows, filtered by the predicate the handler actually wrote.

    A faithful fake for one property only: a row is visible if the statement's
    own ``tenant_id`` predicate admits it, and an UPDATE mutates exactly the
    rows that predicate admits.  That is what Postgres does, and it is what
    turns a dropped predicate into a cross-tenant leak that shows up in an HTTP
    response body rather than only in an assertion about SQL text.
    """

    def __init__(self, rows: dict[str, list[dict[str, Any]]]) -> None:
        self.rows = rows
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    # -- helpers ----------------------------------------------------------

    def _tables(self, sql: str) -> set[str]:
        return {name.lower() for name in _TABLE_REF.findall(sql)}

    def _candidates(self, sql: str, args: tuple[Any, ...]) -> list[dict[str, Any]]:
        tables = self._tables(sql)
        rows = [row for table, rs in self.rows.items() if table in tables for row in rs]

        where = sql.upper().find(" WHERE ")
        clause = sql[where:] if where != -1 else ""

        for match in _ID_EQ.finditer(clause):
            column, position = match.group(1).lower(), int(match.group(2))
            if position > len(args):
                continue
            wanted = args[position - 1]
            rows = [row for row in rows if column in row and row[column] == wanted]

        for match in _NEQ.finditer(clause):
            column, position = match.group(1).lower(), int(match.group(2))
            if position > len(args):
                continue
            wanted = args[position - 1]
            rows = [row for row in rows if column not in row or row[column] != wanted]

        return rows

    def _apply_update(self, sql: str, args: tuple[Any, ...]) -> list[dict[str, Any]]:
        target = self._candidates(sql, args)
        set_start = sql.upper().find(" SET ")
        where_start = sql.upper().find(" WHERE ")
        assignments = sql[set_start:where_start] if set_start != -1 and where_start != -1 else ""
        for row in target:
            for match in _SET_ASSIGN.finditer(assignments):
                column, position = match.group(1).lower(), int(match.group(2))
                if position <= len(args):
                    row[column] = args[position - 1]
        return target

    def _apply_insert(self, sql: str, args: tuple[Any, ...]) -> None:
        tables = self._tables(sql) & set(self.rows)
        for table in tables:
            tenant = args[0] if args else None
            if any(row.get("tenant_id") == tenant for row in self.rows[table]):
                continue  # ON CONFLICT DO NOTHING
            self.rows[table].append(_default_row(table, tenant))

    # -- asyncpg surface --------------------------------------------------

    async def fetch(self, sql: str, *args: Any) -> list[dict[str, Any]]:
        self.statements.append((sql, args))
        return list(self._candidates(sql, args))

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.statements.append((sql, args))
        if sql.lstrip().upper().startswith("UPDATE"):
            updated = self._apply_update(sql, args)
            return updated[0] if updated else None
        found = self._candidates(sql, args)
        return found[0] if found else None

    async def fetchval(self, sql: str, *args: Any) -> Any:
        self.statements.append((sql, args))
        matched = self._candidates(sql, args)
        if "COUNT(" in sql.upper():
            return len(matched)
        return next(iter(matched[0].values())) if matched else None

    async def execute(self, sql: str, *args: Any) -> str:
        self.statements.append((sql, args))
        head = sql.lstrip().upper()
        if head.startswith("UPDATE"):
            self._apply_update(sql, args)
        elif head.startswith("INSERT"):
            self._apply_insert(sql, args)
        return "OK"

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


def _default_row(table: str, tenant: str | None) -> dict[str, Any]:
    if table == "tenant_onboarding":
        return {
            "tenant_id": tenant,
            "status": "pending",
            "completed_at": None,
            "skipped_at": None,
            "wizard_state": {},
        }
    if table == "tenant_settings":
        return {"tenant_id": tenant, "org_name": f"{tenant} Org"}
    return {"tenant_id": tenant}


def onboarding_rows() -> dict[str, list[dict[str, Any]]]:
    return {
        "tenant_onboarding": [
            _default_row("tenant_onboarding", TENANT_A),
            _default_row("tenant_onboarding", TENANT_B),
        ],
        "tenant_settings": [
            _default_row("tenant_settings", TENANT_A),
            _default_row("tenant_settings", TENANT_B),
        ],
        "audit_events": [],
    }


# Every module holding its own binding of ``_get_pool``.  Patching only
# ``api_compat`` leaves the others on the fixture path, which is how a
# cross-tenant test comes out green while testing nothing.  ``demo_runner`` is
# not one of this card's surfaces and was found by the self-check below rather
# than by inspection -- which is the point of having the self-check.
POOL_IMPORTERS = (api_compat, onboarding, audit_ingest, demo_runner)


def _patch_pool(monkeypatch, pool: Any) -> None:
    async def _pool() -> Any:
        return pool

    for module in POOL_IMPORTERS:
        monkeypatch.setattr(module, "_get_pool", _pool)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


async def _noop_close() -> None:
    return None


@pytest.fixture(autouse=True)
def _clean_module_state():
    """The in-memory stores are module-level and outlive a single test.

    ``pytest.ini`` runs this suite under ``-n auto --dist worksteal``, which
    scatters individual tests across workers, so a test that leaves a claim or
    a session behind can change another test's answer inside the same worker.
    """
    for tenant in (TENANT_A, TENANT_B):
        reset_tenant_state(tenant)
    audit_ingest._clear_sessions_for_testing()
    onboarding._FALLBACK.clear()
    yield
    for tenant in (TENANT_A, TENANT_B):
        reset_tenant_state(tenant)
    audit_ingest._clear_sessions_for_testing()
    onboarding._FALLBACK.clear()


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", ISSUER)
    monkeypatch.setattr(settings, "api_jwt_audience", AUDIENCE)
    monkeypatch.setattr(settings, "api_jwt_authorized_party", AZP)
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    # Neither adversary is a superadmin.  Leaving the shipped allowlist in
    # place would make every refusal below depend on these subjects happening
    # not to be on it, which is a property of config rather than of the gate.
    monkeypatch.setattr(settings, "api_superadmin_emails", set())
    monkeypatch.setattr(settings, "api_superadmin_subjects", set())
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWKClient())

    def no_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in adversarial tests")

    monkeypatch.setattr(socket.socket, "connect", no_network)
    set_pool_for_testing(SimpleNamespace(close=_noop_close))
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


@pytest.fixture
def recording_db(monkeypatch):
    pool = RecordingPool()
    _patch_pool(monkeypatch, pool)
    return pool


@pytest.fixture
def onboarding_db(monkeypatch):
    pool = PredicatePool(onboarding_rows())
    _patch_pool(monkeypatch, pool)
    return pool


# ---------------------------------------------------------------------------
# Signed-session builders
# ---------------------------------------------------------------------------

SPIFFE = "spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-nono-evidenced"


def build_chain(session_id: str, events: int = 3, salt: str = "") -> tuple[list[dict[str, Any]], str]:
    """A hash chain that verifies, and the root hash it terminates in.

    ``salt`` varies the event *content*.  It exists because the chain commits
    to the events and nothing else -- ``session_id`` is not an input to
    ``compute_expected_entry_hash`` -- so two sessions with identical events
    terminate in the identical root hash whatever they are called.  A transplant
    test built without a salt compares a signature to itself and passes for the
    wrong reason.  See slon-p3-2-evidence.md, observation O-1.
    """
    chain: list[dict[str, Any]] = []
    prev = GENESIS
    for seq in range(1, events + 1):
        body = {
            "seq": seq,
            "timestamp": f"2026-09-10T10:0{seq}:00Z",
            "event_type": "syscall",
            "action": "openat",
            "resource": f"/workspace/{salt}file-{seq}.txt",
            "detail": {"index": seq, "allowed": True},
        }
        entry = compute_expected_entry_hash(prev, body)
        chain.append({**body, "prev_hash": prev, "entry_hash": entry})
        prev = entry
    return chain, prev


def spiffe_signature(root_hash: str, spiffe_id: str = SPIFFE) -> str:
    return "sig-spiffe-" + hashlib.sha256(f"{root_hash}:{spiffe_id}".encode()).hexdigest()


def valid_session(session_id: str | None = None, salt: str = "", **overrides: Any) -> dict[str, Any]:
    session_id = session_id or f"sess-{uuid.uuid4().hex[:10]}"
    events, root = build_chain(session_id, salt=salt)
    session = {
        "session_id": session_id,
        "agent_id": "agent-nono-evidenced",
        "tenant_id": TENANT_A,
        "spiffe_id": SPIFFE,
        "started_at": "2026-09-10T10:00:00Z",
        "ended_at": "2026-09-10T10:05:00Z",
        "events_count": len(events),
        "root_hash": root,
        "signature": spiffe_signature(root),
        "algorithm": "ECDSA_SHA256",
        "events": events,
        "metadata": {"harness": "nono", "landlock_abi": 4},
    }
    session.update(overrides)
    return session


def wizard(step: int, providers: list[str] | None = None) -> dict[str, Any]:
    """A wizard-state payload using the field names the model actually declares.

    ``OnboardingWizardState`` is ``selected_provider_ids`` / ``step_index`` /
    ``provider_run_state``.  Pydantic drops unknown keys silently, so a payload
    written in the dashboard's camelCase round-trips as an empty state and every
    assertion over it is vacuously true.
    """
    return {
        "step_index": step,
        "selected_provider_ids": providers or [],
        "provider_run_state": {},
    }


WIZARD_SAMPLE = {"step_index": 3, "selected_provider_ids": ["okta"], "provider_run_state": {}}


# ---------------------------------------------------------------------------
# Harness self-checks.  A fake that has drifted from the code it stands in for
# produces confident nonsense, so the fakes are tested before the API is.
# ---------------------------------------------------------------------------


def test_pool_patch_reaches_every_module_that_imported_get_pool():
    """A fourth importer of ``_get_pool`` must not silently escape ``_patch_pool``.

    ``onboarding`` and ``audit_ingest`` both do ``from api_compat import
    _get_pool``, which binds at import time.  If a new module does the same and
    is not added to POOL_IMPORTERS, its routes quietly run on the in-memory
    fixture store while every test in this file believes a database is in play.
    """
    import pathlib

    src = pathlib.Path(__file__).resolve().parent.parent
    importers = set()
    for path in src.glob("*.py"):
        text = path.read_text()
        if re.search(r"from api_compat import\s*\(?[^)]*\b_get_pool\b", text):
            importers.add(path.stem)

    patched = {module.__name__ for module in POOL_IMPORTERS}
    assert importers - patched == set(), (
        f"modules import _get_pool but are not patched by _patch_pool: {importers - patched}"
    )


def test_predicate_pool_leaks_when_the_tenant_predicate_is_absent():
    """The fake must be capable of showing a leak, or it cannot witness one.

    A PredicatePool that filtered by tenant unconditionally -- the way the
    in-memory fixture store does -- would make every cross-tenant assertion in
    this file pass for the wrong reason.
    """
    import asyncio

    pool = PredicatePool(onboarding_rows())
    scoped = asyncio.run(pool.fetch("SELECT * FROM tenant_onboarding WHERE tenant_id = $1", TENANT_A))
    unscoped = asyncio.run(pool.fetch("SELECT * FROM tenant_onboarding WHERE $1 IS NOT NULL", TENANT_A))

    assert len(scoped) == 1 and scoped[0]["tenant_id"] == TENANT_A
    assert len(unscoped) == 2, "the fake cannot demonstrate a leak, so it cannot witness one either"


def test_hash_chain_builder_produces_a_chain_the_service_accepts():
    """Positive control for the tampering tests below.

    Every hash-chain test in this file mutates the output of ``build_chain``.
    If ``build_chain`` produced an invalid chain, all of them would pass for
    the wrong reason.
    """
    session = valid_session()
    ok, err = audit_ingest.verify_hash_chain(
        [audit_ingest.AuditEvent(**e) for e in session["events"]],
        session["root_hash"],
        session["session_id"],
    )
    assert ok, f"builder produced an invalid chain: {err}"


# ---------------------------------------------------------------------------
# 1. Unauthenticated bypass.  ISC-1 .. ISC-13.
# ---------------------------------------------------------------------------

MUTATING_ROUTES = [
    ("post", "/api/onboarding/skip", None),
    ("post", "/api/onboarding/complete", None),
    ("put", "/api/onboarding/state", WIZARD_SAMPLE),
    ("post", "/api/agents/claim", {"pod_name": "p", "spiffe_id": SPIFFE}),
    ("post", "/api/v1/agents/claim", {"pod_name": "p", "spiffe_id": SPIFFE}),
    ("post", "/api/audit/sessions", None),
    ("post", "/api/audit/sessions/verify", None),
]

READ_ROUTES = [
    "/api/onboarding/status",
    "/api/onboarding/state",
    "/api/agents/claims",
    "/api/audit/sessions",
]


@pytest.mark.parametrize("path", READ_ROUTES)
def test_unauthenticated_read_is_refused(client, path):
    """ISC-1, ISC-4 (read half): no header, no data."""
    response = client.get(path)
    assert response.status_code == 401, f"{path} served an unauthenticated reader"
    assert response.json()["error"]["code"] == "authentication_required"


@pytest.mark.parametrize("method,path,body", MUTATING_ROUTES)
def test_unauthenticated_mutation_is_refused(client, method, path, body):
    """ISC-2, ISC-3, ISC-4, ISC-5, ISC-6: every mutating route demands a bearer."""
    payload = body if body is not None else valid_session()
    response = getattr(client, method)(path, json=payload)
    assert response.status_code == 401, f"{method.upper()} {path} accepted an unauthenticated mutation"
    assert response.json()["error"]["code"] == "authentication_required"


@pytest.mark.parametrize(
    "header",
    [
        "Basic YWxpY2U6cGFzcw==",
        "Bearer",
        "Bearer ",
        "bearer",
        "Bearer token with spaces",
        "  Bearer sometoken",
        "Token abc123",
    ],
)
def test_malformed_authorization_header_is_refused(client, header):
    """ISC-7: the scheme parser is not a place to be generous."""
    response = client.get("/api/onboarding/status", headers={"Authorization": header})
    assert response.status_code == 401, f"header {header!r} was accepted"
    assert response.json()["error"]["code"] in {"invalid_token", "authentication_required"}


@pytest.mark.parametrize(
    "token,label",
    [
        ("not-a-jwt-at-all", "opaque garbage"),
        ("aaa.bbb.ccc", "three garbage segments"),
        ("", "empty"),
    ],
)
def test_garbage_bearer_token_is_refused(client, token, label):
    """ISC-8."""
    response = client.get("/api/onboarding/status", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401, f"{label} token was accepted"


def test_expired_token_is_refused(client):
    """ISC-9."""
    response = client.get("/api/onboarding/status", headers=bearer(token_for(ALICE, lifetime=-60)))
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_token"


def test_token_signed_by_an_attacker_key_is_refused(client):
    """ISC-10: correct claims, correct kid, wrong private key."""
    forged = token_for(ALICE, signing_key=ATTACKER_KEY)
    response = client.get("/api/onboarding/status", headers=bearer(forged))
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_token"


def test_alg_none_token_is_refused(client):
    """ISC-11a: the classic unsigned-token bypass.

    NOT falsifiable by mutating this repository, and that is a finding rather
    than a gap.  With BOTH app-level controls removed -- the header check set to
    ``if False`` and the decode list widened to ``["RS256", "HS256", "none"]``
    -- the token is still refused, by PyJWT itself:

        JWTValidationError: invalid Dex JWT
          underlying: JWTValidationError: malformed JWT

    A signature segment that is empty fails structurally before any algorithm
    policy is consulted.  The assertion is real; the control enforcing it lives
    in the dependency, so no mutation of this codebase can turn it red.  See
    slon-p3-2-evidence.md, observation O-2.
    """
    response = client.get(
        "/api/onboarding/status", headers={"Authorization": f"Bearer {unsigned_alg_none_token()}"}
    )
    assert response.status_code == 401, "an unsigned alg:none token was accepted"


def test_hs256_algorithm_confusion_is_refused(client):
    """ISC-11b: the RSA public key replayed as an HMAC secret.

    Three controls stand between this token and a session, and the third is the
    one that actually fires.  With the header check disabled AND HS256 added to
    the decode list, the token is still refused:

        JWTValidationError: invalid Dex JWT
          underlying: TypeError: Expected a string value

    ``_jwk_client`` hands ``jwt.decode`` an ``RSAPublicKey`` *object*, and
    PyJWT's HMAC path refuses a non-string secret.  The classic RS256→HS256
    confusion attack is therefore structurally unavailable here -- but only for
    as long as the key reaches ``decode`` as a key object.  A JWKS client
    refactored to pass PEM *text* would remove that third control and leave the
    app's own ``algorithms=["RS256"]`` list as the sole defence.  This test
    would still pass at that point, which is why the dependency is named here.
    See slon-p3-2-evidence.md, observation O-2.
    """
    response = client.get(
        "/api/onboarding/status", headers={"Authorization": f"Bearer {hs256_confusion_token()}"}
    )
    assert response.status_code == 401, "an HS256 algorithm-confusion token was accepted"


@pytest.mark.parametrize(
    "kwargs,label",
    [
        ({"audience": "some-other-api"}, "wrong audience"),
        ({"issuer": "https://evil.test/dex"}, "wrong issuer"),
        ({"azp": "attacker-client"}, "wrong authorized party"),
        ({"key_id": "attacker-key"}, "unknown key id"),
    ],
)
def test_token_with_wrong_registered_claim_is_refused(client, kwargs, label):
    """ISC-12.

    Falsified by mutations ``jwt_audience``, ``jwt_issuer``, ``jwt_azp``.
    """
    response = client.get("/api/onboarding/status", headers=bearer(token_for(ALICE, **kwargs)))
    assert response.status_code == 401, f"token with {label} was accepted"


def test_authentication_precedes_body_validation(client):
    """ISC-13: an anonymous caller learns nothing about their payload.

    A 422 here would be an oracle -- it would tell an unauthenticated attacker
    which fields the schema wants, one probe at a time.
    """
    response = client.post("/api/audit/sessions", json={"corrupted": True})
    assert response.status_code == 401, (
        f"unauthenticated malformed body returned {response.status_code}; "
        "body validation must not run before authentication"
    )
    assert "session_id" not in response.text, "the error disclosed a schema field name"


def test_a_valid_token_is_accepted(client):
    """Positive control for the whole 401 group.

    Without this, a service that refused every request would pass every test
    above.
    """
    response = client.get("/api/onboarding/status", headers=bearer(ALICE))
    assert response.status_code == 200, response.text
    assert response.json()["status"] in {"pending", "completed", "skipped"}


# ---------------------------------------------------------------------------
# 2. The tenant boundary.  ISC-14 .. ISC-25.
# ---------------------------------------------------------------------------

GUARDED_PREFIXES = ("/api/onboarding", "/api/audit", "/api/agents", "/api/v1/agents")


def test_no_route_accepts_a_caller_supplied_tenant(client):
    """ISC-14: there is no tenant parameter to tamper with, on any guarded route.

    This is the assertion that replaces the card's "403 on tenant mismatch".
    The tenant is not an input, so a mismatch is unrepresentable -- which is a
    stronger property than refusing one.  The moment somebody adds
    ``/api/onboarding/{tenant_id}/status`` this test fails, which is exactly
    when it should.
    """
    offenders = []
    for route in app.routes:
        path = getattr(route, "path", "")
        endpoint = getattr(route, "endpoint", None)
        if not path.startswith(GUARDED_PREFIXES) or endpoint is None:
            continue

        if re.search(r"\{[^}]*tenant[^}]*\}", path, re.I):
            offenders.append((path, "path parameter"))
            continue

        for name, parameter in inspect.signature(endpoint).parameters.items():
            if "tenant" not in name.lower():
                continue
            # A ``tenant_id`` that is Depends(authenticated_tenant) is the
            # server deriving it, not the caller supplying it.
            annotation = str(parameter.annotation)
            if "authenticated_tenant" in annotation or "authenticated_principal" in annotation:
                continue
            offenders.append((path, f"handler parameter {name!r}"))

    assert offenders == [], f"routes accept a caller-supplied tenant: {offenders}"


def test_forged_tenant_claim_in_the_token_is_ignored(client, onboarding_db):
    """ISC-15: a ``tenant_id`` claim in the JWT does not move the caller.

    Falsified by mutation ``subject_tenant_map``, which changes the lookup to
    ``claims.get("tenant_id") or settings.api_subject_tenants.get(...)``.
    """
    forged = token_for(ALICE, extra_claims={"tenant_id": TENANT_B, "tenant": TENANT_B})
    client.put(
        "/api/onboarding/state",
        headers=bearer(forged),
        json=wizard(9, ["okta"]),
    )

    writes = [
        (sql, args)
        for sql, args in onboarding_db.statements
        if sql.lstrip().upper().startswith("UPDATE") and "tenant_onboarding" in sql
    ]
    assert writes, "the forged-claim request issued no write to inspect"
    for sql, args in writes:
        assert TENANT_B not in args, (
            f"a tenant_id claim in the token reached the database: {sql!r} bound {args!r}"
        )
        assert TENANT_A in args, "the write was not scoped to the subject's configured tenant"


def test_subject_with_no_tenant_mapping_is_refused_with_403(client):
    """ISC-16: the one place 403 genuinely lives.

    Mallory holds a perfectly valid, correctly signed token.  Authentication
    succeeds and authorization does not.
    """
    response = client.get("/api/onboarding/status", headers=bearer(MALLORY))
    assert response.status_code == 403, response.text
    assert response.json()["error"]["code"] == "tenant_forbidden"


@pytest.mark.parametrize("path", READ_ROUTES + ["/api/onboarding/state"])
def test_unmapped_subject_is_refused_everywhere(client, path):
    """ISC-16 (sweep): the 403 is not a property of one handler."""
    assert client.get(path, headers=bearer(MALLORY)).status_code == 403


def test_wizard_state_written_by_one_tenant_is_invisible_to_the_other(client, onboarding_db):
    """ISC-17: the leak, demonstrated as an HTTP response body.

    Falsified by mutation ``onboarding_wizard_write_tenant_filter``: with the
    predicate removed the UPDATE hits both rows and Bob reads Alice's wizard.
    """
    secret = wizard(7, ["alice-only-idp"])
    written = client.put("/api/onboarding/state", headers=bearer(ALICE), json=secret)
    assert written.status_code == 200, written.text

    # Assert the write round-trips before asserting the other tenant cannot see
    # it.  Without this, a payload the model discards makes the leak assertion
    # vacuously true -- which is how the first draft of this test passed while
    # checking nothing: the fields were camelCase and OnboardingWizardState
    # silently ignores unknown keys.
    mine = client.get("/api/onboarding/state", headers=bearer(ALICE))
    assert mine.json()["step_index"] == 7, f"the write did not persist: {mine.text}"
    assert mine.json()["selected_provider_ids"] == ["alice-only-idp"]

    seen = client.get("/api/onboarding/state", headers=bearer(BOB))
    assert seen.status_code == 200, seen.text
    assert seen.json()["step_index"] != 7, "tenant B observed tenant A's wizard progress"
    assert "alice-only-idp" not in seen.text


def test_terminal_transition_by_one_tenant_does_not_move_the_other(client, onboarding_db):
    """ISC-18.

    Falsified by mutation ``onboarding_terminal_tenant_filter``: with the
    predicate removed the UPDATE marks both tenants complete.
    """
    completed = client.post("/api/onboarding/complete", headers=bearer(ALICE))
    assert completed.status_code == 200, completed.text
    assert completed.json()["status"] == "completed"

    other = client.get("/api/onboarding/status", headers=bearer(BOB))
    assert other.status_code == 200, other.text
    assert other.json()["status"] == "pending", "tenant A's completion moved tenant B"
    assert other.json()["completed_at"] is None


def unscoped_statements(pool: Any, tenant: str) -> list[tuple[str, tuple[Any, ...]]]:
    """Statements touching a tenant-owned table without binding this tenant.

    Two ways to be scoped, because the SQL in these modules uses both: a
    ``tenant_id = $N`` predicate whose bound argument is the caller's tenant,
    or an INSERT that writes the caller's tenant into the row.
    """
    offenders = []
    for sql, args in pool.statements:
        touched = {name.lower() for name in _TABLE_REF.findall(sql)} & TENANT_OWNED_TABLES
        if not touched:
            continue
        bound = {index for index, value in enumerate(args, start=1) if value == tenant}
        predicates = {int(m.group(1)) for m in _TENANT_EQ.finditer(sql)}
        if predicates & bound:
            continue
        if sql.lstrip().upper().startswith("INSERT") and bound:
            continue
        offenders.append((sql, args))
    return offenders


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("get", "/api/onboarding/status", None),
        ("get", "/api/onboarding/state", None),
        ("put", "/api/onboarding/state", wizard(2, ["entra"])),
        ("post", "/api/onboarding/skip", None),
        ("post", "/api/onboarding/complete", None),
    ],
)
def test_every_onboarding_statement_binds_the_callers_tenant(client, recording_db, method, path, body):
    """ISC-19: the mechanism, not a sample of its effects.

    The recording pool returns nothing, so the handler may well fail after
    issuing its SQL.  The SQL is the subject.
    """
    kwargs = {"headers": bearer(ALICE)}
    if body is not None:
        kwargs["json"] = body
    getattr(client, method)(path, **kwargs)

    assert recording_db.statements, f"{method.upper()} {path} never reached the database"
    offenders = unscoped_statements(recording_db, TENANT_A)
    assert offenders == [], f"{method.upper()} {path} issued cross-tenant-reachable SQL: {offenders}"


def test_audit_session_body_cannot_choose_its_own_tenant(client):
    """ISC-21: ``SignedAuditSession.tenant_id`` is an attacker-controlled field.

    It is declared in the model with a default of ``"tenant-demo"``, so a
    client can set it to anything.  The handler overwrites it from the token.
    """
    session = valid_session(tenant_id=TENANT_B)
    response = client.post("/api/audit/sessions", headers=bearer(ALICE), json=session)
    assert response.status_code == 201, response.text
    assert response.json()["tenant_id"] == TENANT_A, (
        "the request body chose the tenant the session was filed under"
    )

    # And it is filed where the token said, not where the body said.
    assert client.get(f"/api/audit/sessions/{session['session_id']}", headers=bearer(BOB)).status_code == 404

    # The stored record, not just the response envelope.  The envelope is built
    # from the dependency-resolved tenant, so it reads correctly even when the
    # persisted row does not -- mutation ``audit_session_body_tenant_override``
    # survived the first version of this test for exactly that reason.
    stored = client.get(f"/api/audit/sessions/{session['session_id']}", headers=bearer(ALICE))
    assert stored.status_code == 200, stored.text
    assert stored.json()["tenant_id"] == TENANT_A, (
        "the persisted audit record was filed under the tenant named in the request body"
    )


def test_audit_session_is_not_retrievable_by_another_tenant(client):
    """ISC-22.  404 rather than 403 is deliberate and correct: a 403 would
    confirm the identifier exists, which is an oracle for enumeration.
    """
    session = valid_session()
    assert client.post("/api/audit/sessions", headers=bearer(ALICE), json=session).status_code == 201

    intruder = client.get(f"/api/audit/sessions/{session['session_id']}", headers=bearer(BOB))
    assert intruder.status_code == 404
    assert session["root_hash"] not in intruder.text


def test_audit_session_list_is_partitioned(client):
    """ISC-23."""
    mine = valid_session()
    assert client.post("/api/audit/sessions", headers=bearer(ALICE), json=mine).status_code == 201

    listed = client.get("/api/audit/sessions", headers=bearer(BOB))
    assert listed.status_code == 200, listed.text
    assert listed.json()["total"] == 0
    assert mine["session_id"] not in listed.text


@pytest.mark.parametrize(
    "path",
    [
        "/api/agents/claims",
        "/api/agents/claim/claim-whatever",
        "/api/v1/agents/claims",
        "/api/v1/agents/claim/claim-whatever",
    ],
)
def test_claim_reads_bind_the_callers_tenant_in_sql(client, recording_db, path):
    """ISC-24/25 on the database branch.

    ``test_claim_is_not_retrievable_by_another_tenant`` runs on the in-memory
    ``_CLAIMS`` store, which is keyed by tenant -- so it holds whatever the SQL
    says.  Mutation ``claim_detail_tenant_filter`` survived that test and is
    caught here.
    """
    client.get(path, headers=bearer(ALICE))

    assert recording_db.statements, f"GET {path} never reached the database"
    offenders = unscoped_statements(recording_db, TENANT_A)
    assert offenders == [], f"GET {path} issued cross-tenant-reachable SQL: {offenders}"


def test_audit_session_db_reads_bind_the_callers_tenant(client, recording_db):
    """ISC-22/23 on the database branch.

    The in-memory session store is keyed ``f"{tenant}:{id}"``, so partitioning
    holds there by data structure.  That proves nothing about the SQL, which is
    what runs in production.
    """
    client.get("/api/audit/sessions", headers=bearer(ALICE))
    client.get("/api/audit/sessions/whatever", headers=bearer(ALICE))

    assert recording_db.statements, "audit session reads never reached the database"
    offenders = unscoped_statements(recording_db, TENANT_A)
    assert offenders == [], f"audit session reads issued cross-tenant-reachable SQL: {offenders}"


def _claim_body(pod: str) -> dict[str, Any]:
    return {
        "pod_name": pod,
        "namespace": "fe-signalloom-agents",
        "spiffe_id": f"spiffe://cluster.local/ns/fe-signalloom-agents/sa/{pod}",
        "harness": "claude-code",
        "model": "claude-3-5-sonnet",
        "token_budget_limit": 100000,
    }


def test_claim_is_not_retrievable_by_another_tenant(client):
    """ISC-24."""
    pod = f"adv-pod-{uuid.uuid4().hex[:8]}"
    granted = client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))
    assert granted.status_code == 200, granted.text
    claim_id = granted.json()["claim_id"]

    assert client.get(f"/api/agents/claim/{claim_id}", headers=bearer(ALICE)).status_code == 200
    intruder = client.get(f"/api/agents/claim/{claim_id}", headers=bearer(BOB))
    assert intruder.status_code == 404, "tenant B read tenant A's claim"
    assert pod not in intruder.text


def test_claim_list_is_partitioned(client):
    """ISC-25."""
    pod = f"adv-pod-{uuid.uuid4().hex[:8]}"
    assert client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod)).status_code == 200

    listed = client.get("/api/agents/claims", headers=bearer(BOB))
    assert listed.status_code == 200, listed.text
    assert pod not in listed.text
    assert all(record["pod_name"] != pod for record in listed.json()["claims"])


# ---------------------------------------------------------------------------
# 3. Claim tampering.  ISC-26 .. ISC-31.
# ---------------------------------------------------------------------------


def test_claiming_an_agent_owned_by_another_tenant_is_a_conflict(client):
    """ISC-26: the card's headline assertion."""
    pod = f"contested-{uuid.uuid4().hex[:8]}"
    assert client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod)).status_code == 200

    stolen = client.post("/api/agents/claim", headers=bearer(BOB), json=_claim_body(pod))
    assert stolen.status_code == 409, f"tenant B claimed tenant A's agent: {stolen.status_code}"
    assert stolen.json()["error"]["code"] == "claim_conflict"


def test_claim_conflict_response_leaks_nothing(client):
    """ISC-27: a refusal must not become a reconnaissance channel."""
    pod = f"contested-{uuid.uuid4().hex[:8]}"
    client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))
    stolen = client.post("/api/agents/claim", headers=bearer(BOB), json=_claim_body(pod))

    body = stolen.text
    for marker in ("Traceback", "File \"/", "SELECT ", "INSERT ", "asyncpg", "postgresql://", "/app/", "site-packages"):
        assert marker not in body, f"conflict response leaked {marker!r}"


def test_claim_conflict_does_not_name_the_owning_tenant(client):
    """ISC-27.1 -- a defect this card found and fixed.

    The 409 message used to read ``already claimed by tenant 'tenant-adv-a'``.
    Bob has no relationship with tenant A and no business learning it exists.
    Worse, the message turns a pod-name guessing loop into a tenant enumerator:
    a caller who can guess workload names can harvest the tenant identifiers
    that own them, one 409 at a time.

    Falsified by mutation ``claim_conflict_discloses_owner``, which restores the
    original message on the in-memory branch.
    """
    pod = f"contested-{uuid.uuid4().hex[:8]}"
    assert client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod)).status_code == 200

    stolen = client.post("/api/agents/claim", headers=bearer(BOB), json=_claim_body(pod))
    assert stolen.status_code == 409, stolen.text
    assert stolen.json()["error"]["code"] == "claim_conflict"

    assert TENANT_A not in stolen.text, (
        f"the conflict named the owning tenant: {stolen.json()['error']['message']!r}"
    )
    # The refusal must still be actionable -- "no" with no reason is its own
    # defect, and a message stripped to nothing would pass the line above.
    assert pod in stolen.text, "the refusal does not say which agent was refused"
    assert "another tenant" in stolen.json()["error"]["message"]


def test_conflict_fires_on_agent_id_collision_as_well_as_pod_name(client):
    """ISC-28: the conflict predicate is ``agent_id = $1 OR pod_name = $2``.

    A tenant renaming the pod while keeping the agent id must not slip past.
    """
    pod = f"contested-{uuid.uuid4().hex[:8]}"
    granted = client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))
    assert granted.status_code == 200, granted.text
    agent_id = granted.json()["agent_id"]

    renamed = _claim_body(f"{pod}-renamed")
    renamed["agent_id"] = agent_id
    stolen = client.post("/api/agents/claim", headers=bearer(BOB), json=renamed)
    assert stolen.status_code == 409, "a renamed pod carrying the same agent_id was claimed"
    assert stolen.json()["error"]["code"] == "claim_conflict"


def test_same_tenant_reclaim_is_idempotent_not_a_conflict(client):
    """ISC-30, and the positive control for the 409 group.

    A service that returned 409 to every claim would satisfy ISC-26 through
    ISC-28 without holding any boundary at all.
    """
    pod = f"mine-{uuid.uuid4().hex[:8]}"
    first = client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))
    second = client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))

    assert first.status_code == 200, first.text
    assert second.status_code == 200, f"a tenant was refused its own agent: {second.text}"
    assert first.json()["agent_id"] == second.json()["agent_id"]


def test_released_claim_does_not_block_another_tenant(client):
    """ISC-29: the conflict predicate carries ``released_at IS NULL``.

    A released claim that kept blocking would be a denial-of-service by
    squatting, and the assertion also proves the conflict is not simply
    "anything with this pod name is forbidden".
    """
    pod = f"handover-{uuid.uuid4().hex[:8]}"
    granted = client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))
    assert granted.status_code == 200, granted.text

    released = client.delete(f"/api/agents/claim/{granted.json()['claim_id']}", headers=bearer(ALICE))
    assert released.status_code == 200, released.text

    handover = client.post("/api/agents/claim", headers=bearer(BOB), json=_claim_body(pod))
    assert handover.status_code == 200, f"a released claim still blocked a new tenant: {handover.text}"


def test_cross_tenant_conflict_is_checked_on_the_database_branch(client, recording_db):
    """ISC-31: the in-memory conflict loop is not the production control.

    The database branch must issue a conflict lookup that excludes the caller's
    own tenant -- ``tenant_id != $3`` -- before it inserts anything.  Asserting
    on the in-memory loop alone would leave the SQL untested, which is the
    shape of defect this file exists to catch.
    """
    pod = f"dbcheck-{uuid.uuid4().hex[:8]}"
    client.post("/api/agents/claim", headers=bearer(ALICE), json=_claim_body(pod))

    conflict_lookups = [
        (sql, args)
        for sql, args in recording_db.statements
        if "agent_claims" in sql and sql.lstrip().upper().startswith("SELECT")
    ]
    assert conflict_lookups, "the database branch inserted a claim without checking for a conflict first"

    sql, args = conflict_lookups[0]
    assert re.search(r"tenant_id\s*!=\s*\$(\d+)", sql), (
        f"the conflict lookup does not exclude the caller's own tenant: {sql!r}"
    )
    assert "released_at IS NULL" in sql, "the conflict lookup would match already-released claims"
    assert TENANT_A in args, "the conflict lookup did not bind the caller's tenant"


# ---------------------------------------------------------------------------
# 4. Forged Nono evidence.  ISC-32 .. ISC-41.
# ---------------------------------------------------------------------------


def test_valid_signed_session_is_accepted(client):
    """Positive control for the whole 400 group."""
    response = client.post("/api/audit/sessions", headers=bearer(ALICE), json=valid_session())
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["valid"] is True
    assert body["hash_chain_valid"] is True
    assert body["signature_valid"] is True
    assert body["events_verified"] == 3


def _tampered(mutate) -> dict[str, Any]:
    session = valid_session()
    mutate(session)
    # Re-sign over whatever root hash the tamper left behind, so the signature
    # is never the reason a hash-chain test fails.
    session["signature"] = spiffe_signature(session["root_hash"])
    return session


def _corrupt_entry_hash(session):
    session["events"][1]["entry_hash"] = "f" * 64
    session["root_hash"] = session["events"][-1]["entry_hash"]


def _break_prev_hash_linkage(session):
    session["events"][2]["prev_hash"] = "a" * 64


def _mutate_event_payload_leaving_hashes(session):
    # The attacker edits what the agent did and leaves the hashes untouched,
    # hoping nobody recomputes them.
    session["events"][0]["resource"] = "/etc/shadow"
    session["events"][0]["detail"] = {"index": 1, "allowed": True, "exfiltrated": True}


def _detach_root_hash(session):
    session["root_hash"] = "b" * 64


def _truncate_the_log(session):
    # Drop the middle event -- the cheapest way to hide one action.
    del session["events"][1]


@pytest.mark.parametrize(
    "mutate,label",
    [
        (_corrupt_entry_hash, "recomputed entry_hash"),
        (_break_prev_hash_linkage, "broken prev_hash linkage"),
        (_mutate_event_payload_leaving_hashes, "edited event payload"),
        (_detach_root_hash, "root_hash detached from the chain"),
        (_truncate_the_log, "truncated event log"),
    ],
)
def test_tampered_hash_chain_is_rejected(client, mutate, label):
    """ISC-32, ISC-33, ISC-34, ISC-35."""
    response = client.post("/api/audit/sessions", headers=bearer(ALICE), json=_tampered(mutate))
    assert response.status_code == 400, f"{label} was ingested as valid evidence"
    assert response.json()["error"]["code"] == "hash_chain_verification_failed"


@pytest.mark.parametrize(
    "signature,label",
    [
        ("", "empty"),
        ("   ", "whitespace"),
        ("sig-spiffe-" + "0" * 64, "wrong SPIFFE digest"),
        ("deadbeef", "opaque hex"),
        ("not-a-signature-at-all", "free text"),
    ],
)
def test_invalid_signature_is_rejected(client, signature, label):
    """ISC-36, ISC-37."""
    response = client.post(
        "/api/audit/sessions", headers=bearer(ALICE), json=valid_session(signature=signature)
    )
    assert response.status_code == 400, f"{label} signature was accepted"
    assert response.json()["error"]["code"] == "signature_verification_failed"


def test_signature_transplanted_from_another_session_is_rejected(client):
    """ISC-38: replaying a genuine signature onto different evidence.

    The signature is over the root hash, so a signature lifted from a real
    session must not authenticate a fabricated one.
    """
    donor = valid_session(salt="donor-")
    forgery = valid_session(salt="forged-", signature=donor["signature"])
    assert forgery["root_hash"] != donor["root_hash"], "the two sessions must differ for this to be a transplant"

    response = client.post("/api/audit/sessions", headers=bearer(ALICE), json=forgery)
    assert response.status_code == 400, "a transplanted signature authenticated different evidence"
    assert response.json()["error"]["code"] == "signature_verification_failed"


def test_genuine_ecdsa_signature_over_the_wrong_data_is_rejected(client):
    """ISC-39: real cryptography, wrong message.

    Not a malformed-signature test -- the bytes verify perfectly against a
    different payload, which is what a replay actually looks like.
    """
    key = ec.generate_private_key(ec.SECP256R1())
    public_pem = (
        key.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )
    session = valid_session()
    wrong_signature = key.sign(b"some other root hash entirely", ec.ECDSA(hashes.SHA256()))
    session["public_key"] = public_pem
    session["signature"] = base64.b64encode(wrong_signature).decode()

    response = client.post("/api/audit/sessions", headers=bearer(ALICE), json=session)
    assert response.status_code == 400, "an ECDSA signature over the wrong data was accepted"
    assert response.json()["error"]["code"] == "signature_verification_failed"


def test_genuine_ecdsa_signature_over_the_right_data_is_accepted(client):
    """Positive control for ISC-39 -- proves the ECDSA path can succeed at all."""
    key = ec.generate_private_key(ec.SECP256R1())
    public_pem = (
        key.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )
    session = valid_session()
    signature = key.sign(session["root_hash"].encode(), ec.ECDSA(hashes.SHA256()))
    session["public_key"] = public_pem
    session["signature"] = base64.b64encode(signature).decode()

    response = client.post("/api/audit/sessions", headers=bearer(ALICE), json=session)
    assert response.status_code == 201, response.text


@pytest.mark.parametrize(
    "build,label",
    [
        (lambda: _tampered(_corrupt_entry_hash), "tampered chain"),
        (lambda: valid_session(signature="sig-spiffe-" + "0" * 64), "bad signature"),
    ],
)
def test_rejected_evidence_is_never_persisted(client, build, label):
    """ISC-40: a refusal that still files the record is not a refusal.

    Discarded evidence must leave no trace in the store or the list, or the
    audit trail carries material the service itself declared unverifiable.
    """
    session = build()
    assert client.post("/api/audit/sessions", headers=bearer(ALICE), json=session).status_code == 400

    fetched = client.get(f"/api/audit/sessions/{session['session_id']}", headers=bearer(ALICE))
    assert fetched.status_code == 404, f"{label} was persisted despite rejection"

    listed = client.get("/api/audit/sessions", headers=bearer(ALICE))
    assert listed.json()["total"] == 0, f"{label} appeared in the session list"
    assert session["session_id"] not in listed.text


def test_verify_probe_reports_invalid_without_persisting(client):
    """ISC-41: the read-only probe grades evidence, it does not accept it."""
    session = _tampered(_corrupt_entry_hash)
    probe = client.post("/api/audit/sessions/verify", headers=bearer(ALICE), json=session)

    assert probe.status_code == 200, probe.text
    body = probe.json()
    assert body["valid"] is False
    assert body["hash_chain_valid"] is False
    assert body["events_verified"] == 0
    assert body["error"], "the probe reported invalid without saying why"

    assert client.get(f"/api/audit/sessions/{session['session_id']}", headers=bearer(ALICE)).status_code == 404


# ---------------------------------------------------------------------------
# 5. Concurrency.  ISC-42, ISC-43.
# ---------------------------------------------------------------------------


def test_concurrent_two_tenant_onboarding_preserves_partitioning(client, onboarding_db):
    """ISC-42: an adversarial burst must not blur the boundary.

    Interleaving is what turns a read-then-write into a lost update.  Here the
    guard is in SQL (``WHERE tenant_id = $1 AND status <> $2``) rather than a
    Python check, so concurrency should not be able to cross it.
    """
    def work(subject: str, step: int) -> int:
        return client.put(
            "/api/onboarding/state",
            headers=bearer(subject),
            json=wizard(step, [f"provider-{step}"]),
        ).status_code

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda i: work(ALICE if i % 2 else BOB, 3 if i % 2 else 8), range(16)))

    assert set(results) == {200}, f"a concurrent write failed: {results}"
    assert client.get("/api/onboarding/state", headers=bearer(ALICE)).json()["step_index"] == 3
    assert client.get("/api/onboarding/state", headers=bearer(BOB)).json()["step_index"] == 8


def test_concurrent_claims_of_one_pod_yield_exactly_one_owner(client):
    """ISC-43: two tenants racing for the same agent.

    Exactly one grant is the whole point.  Two grants would mean two tenants
    believe they govern the same workload, which is the failure this endpoint
    exists to prevent.
    """
    pod = f"race-{uuid.uuid4().hex[:8]}"

    def attempt(subject: str) -> int:
        return client.post("/api/agents/claim", headers=bearer(subject), json=_claim_body(pod)).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        first, second = pool.map(attempt, (ALICE, BOB))

    outcomes = sorted([first, second])
    assert outcomes in ([200, 409], [409, 200], [200, 200]), f"unexpected race outcome: {outcomes}"

    # Whatever the interleaving, the pod must end up owned by exactly one tenant.
    owners = {
        tenant
        for tenant, subject in ((TENANT_A, ALICE), (TENANT_B, BOB))
        if any(
            record["pod_name"] == pod
            for record in client.get("/api/agents/claims", headers=bearer(subject)).json()["claims"]
        )
    }
    assert len(owners) == 1, f"a contested pod ended up claimed by {len(owners)} tenants: {owners}"


# ---------------------------------------------------------------------------
# 6. Anti-criteria.  ISC-45, ISC-46.
# ---------------------------------------------------------------------------


def test_no_adversarial_response_leaks_implementation_detail(client):
    """ISC-46: sweep every refusal in this file for reconnaissance value."""
    leak_markers = (
        "Traceback",
        'File "/',
        "site-packages",
        "asyncpg",
        "postgresql://",
        "SELECT ",
        "INSERT ",
        "UPDATE ",
        "/app/",
        "api_compat.py",
        "onboarding.py",
        "audit_ingest.py",
    )

    responses = [
        client.get("/api/onboarding/status"),
        client.get("/api/onboarding/status", headers={"Authorization": "Bearer garbage"}),
        client.get("/api/onboarding/status", headers=bearer(MALLORY)),
        client.post("/api/audit/sessions", headers=bearer(ALICE), json=_tampered(_corrupt_entry_hash)),
        client.post("/api/audit/sessions", headers=bearer(ALICE), json=valid_session(signature="x")),
        client.get("/api/audit/sessions/does-not-exist", headers=bearer(ALICE)),
        client.get("/api/agents/claim/does-not-exist", headers=bearer(ALICE)),
        client.post("/api/agents/claim", headers=bearer(ALICE), json={"pod_name": 5}),
    ]

    for response in responses:
        for marker in leak_markers:
            assert marker not in response.text, (
                f"{response.request.method} {response.request.url.path} "
                f"returned {response.status_code} and leaked {marker!r}"
            )


def test_the_suite_makes_no_external_network_connection(client):
    """ISC-45: the trap is installed, and it bites.

    Without this the ``no_network`` monkeypatch could be silently removed from
    the fixture and nothing would notice.
    """
    with pytest.raises(AssertionError, match="external network access is forbidden"):
        socket.socket().connect(("198.51.100.1", 443))
