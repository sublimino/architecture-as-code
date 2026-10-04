"""Invites and subject binding (invites.py, migrations 053 and 054).

Always two tenants: a single-tenant fixture cannot tell "bound to the right
tenant" from "bound to whatever tenant there is". What has to hold:

* a binding in ``subject_tenants`` wins over ``API_SUBJECT_TENANTS``, and the
  environment map still works for a subject the table does not know;
* the token is returned once and only its sha256 is stored;
* redeem binds the *verified* subject, refuses a subject already bound to
  another tenant (409), an expired or spent invite (410), and the wrong email;
* create and list are superadmin-only, and list never returns a token;
* a freshly redeemed subject is live on its very next request (cache).
"""
from __future__ import annotations

import hashlib
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
import pytest

import api_compat
import invites
from tests.test_agent_discovery import TEST_SIGNING_KEY as SIGNING_KEY, bearer, client_for

SUPERADMIN = "demo-user"
SUBJECTS = {"alice": "tenant-a", "bob": "tenant-b", SUPERADMIN: "tenant-demo"}


def token_with_email(subject: str, email: str | None) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "sub": subject,
        "azp": "signalloom-dashboard",
    }
    if email is not None:
        claims["email"] = email
    return jwt.encode(claims, SIGNING_KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"})


class _TablePool:
    """Just enough Postgres for invites.py: three tables, matched by SQL text."""

    def __init__(self) -> None:
        self.invites: list[dict[str, Any]] = []
        self.subject_tenants: dict[str, dict[str, Any]] = {}
        self.audit: list[tuple[Any, ...]] = []
        self.statements: list[str] = []
        self.binding_lookups = 0

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self

    async def fetchrow(self, sql: str, *args: Any) -> dict[str, Any] | None:
        self.statements.append(sql)
        if "FROM subject_tenants" in sql:
            self.binding_lookups += 1
            return self.subject_tenants.get(args[0])
        if "INSERT INTO invites" in sql:
            row = {
                "id": uuid.uuid4(), "token_hash": args[0], "email": args[1], "tenant": args[2],
                "created_by": args[3], "created_at": args[4], "expires_at": args[5],
                "redeemed_by": None, "redeemed_at": None,
            }
            self.invites.append(row)
            return dict(row)
        if "FROM invites" in sql and "token_hash = $1" in sql:
            return next((dict(r) for r in self.invites if r["token_hash"] == args[0]), None)
        raise AssertionError(f"unexpected fetchrow: {sql}")

    async def fetch(self, sql: str, *args: Any) -> list[dict[str, Any]]:
        self.statements.append(sql)
        if "FROM invites" in sql:
            return [dict(r) for r in sorted(self.invites, key=lambda r: r["created_at"], reverse=True)]
        raise AssertionError(f"unexpected fetch: {sql}")

    async def execute(self, sql: str, *args: Any) -> str:
        self.statements.append(sql)
        if "UPDATE invites" in sql:
            for row in self.invites:
                if row["id"] == args[0]:
                    row["redeemed_by"], row["redeemed_at"] = args[1], args[2]
            return "UPDATE 1"
        if "INSERT INTO subject_tenants" in sql:
            self.subject_tenants[args[0]] = {"subject": args[0], "tenant": args[1], "bound_via": "invite", "bound_at": args[2]}
            return "INSERT 0 1"
        if "INSERT INTO audit_events" in sql:
            self.audit.append(args)
            return "INSERT 0 1"
        raise AssertionError(f"unexpected execute: {sql}")


@pytest.fixture
def pool(monkeypatch):
    table = _TablePool()

    async def get_pool():
        return table

    return table, get_pool


def _configure(monkeypatch, get_pool):
    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
    monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {SUPERADMIN})
    monkeypatch.setattr(api_compat.settings, "api_superadmin_emails", set())


def _create(client, email="carol@example.test", tenant="tenant-b", subject=SUPERADMIN):
    return client.post("/api/v1/invites", json={"email": email, "tenant": tenant}, headers=bearer(token_with_email(subject, None)))


def test_create_returns_the_token_once_and_stores_only_its_hash(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        response = _create(client)

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["tenant"] == "tenant-b" and body["email"] == "carol@example.test"
    assert body["status"] == "pending" and body["created_by"] == SUPERADMIN
    token = body["token"]
    assert len(token) >= 32
    assert table.invites[0]["token_hash"] == hashlib.sha256(token.encode()).hexdigest()
    assert token not in str(table.invites)
    # Audited under the invite's tenant, by the issuing superadmin.
    assert table.audit and table.audit[0][0] == "tenant-b" and table.audit[0][1] == "invite.created"
    assert table.audit[0][4] == SUPERADMIN


def test_create_and_list_are_superadmin_only(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        created = _create(client, subject="alice")
        listed = client.get("/api/v1/invites", headers=bearer(token_with_email("alice", None)))
        anonymous = client.post("/api/v1/invites", json={"email": "x@y.z", "tenant": "tenant-a"})

    assert created.status_code == 403 and created.json()["error"]["code"] == "superadmin_required"
    assert listed.status_code == 403
    assert anonymous.status_code == 401
    assert table.invites == []


def test_list_never_returns_a_token_or_hash(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        token = _create(client).json()["token"]
        response = client.get("/api/v1/invites", headers=bearer(token_with_email(SUPERADMIN, None)))

    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["invites"]) == 1
    row = body["invites"][0]
    assert "token" not in row and "token_hash" not in row
    assert token not in response.text and hashlib.sha256(token.encode()).hexdigest() not in response.text


def test_an_unbound_subject_redeems_and_is_live_on_its_next_request(monkeypatch, pool):
    """carol is in neither the table nor the environment map: 403 before, tenant-b after."""
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        token = _create(client, email="carol@example.test", tenant="tenant-b").json()["token"]
        carol = bearer(token_with_email("carol", "carol@example.test"))

        before = client.get("/api/v1/me", headers=carol)
        redeemed = client.post("/api/v1/invites/redeem", json={"token": token}, headers=carol)
        after = client.get("/api/v1/me", headers=carol)

    assert before.status_code == 403 and before.json()["error"]["code"] == "tenant_forbidden"
    assert redeemed.status_code == 200, redeemed.text
    assert redeemed.json()["tenant"] == "tenant-b" and redeemed.json()["subject"] == "carol"
    assert after.status_code == 200, after.text
    assert after.json() == {"subject": "carol", "tenant": "tenant-b", "email": "carol@example.test", "superadmin": False}
    assert table.subject_tenants["carol"]["tenant"] == "tenant-b"
    assert table.invites[0]["redeemed_by"] == "carol"
    # Audited under the tenant the subject now belongs to, in the subject's own name.
    redeemed_events = [a for a in table.audit if a[1] == "invite.redeemed"]
    assert redeemed_events and redeemed_events[0][0] == "tenant-b" and redeemed_events[0][4] == "carol@example.test"


def test_the_binding_table_wins_over_the_environment_map(monkeypatch, pool):
    """alice is tenant-a by environment; a table row for tenant-b takes precedence."""
    table, get_pool = pool
    table.subject_tenants["alice"] = {"subject": "alice", "tenant": "tenant-b", "bound_via": "operator", "bound_at": datetime.now(timezone.utc)}
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        alice = client.get("/api/v1/me", headers=bearer(token_with_email("alice", None)))
        bob = client.get("/api/v1/me", headers=bearer(token_with_email("bob", None)))

    assert alice.json()["tenant"] == "tenant-b", alice.text
    assert bob.json()["tenant"] == "tenant-b", bob.text  # environment map, no table row


def test_the_binding_is_cached_rather_than_queried_per_request(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        for _ in range(5):
            assert client.get("/api/v1/me", headers=bearer(token_with_email("alice", None))).status_code == 200

    assert table.binding_lookups == 1


def test_a_subject_bound_to_another_tenant_is_refused_with_409(monkeypatch, pool):
    """alice is tenant-a; an invite for tenant-b must not move her silently."""
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        token = _create(client, email="alice@example.test", tenant="tenant-b").json()["token"]
        response = client.post("/api/v1/invites/redeem", json={"token": token}, headers=bearer(token_with_email("alice", "alice@example.test")))
        me = client.get("/api/v1/me", headers=bearer(token_with_email("alice", None)))

    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "tenant_mismatch"
    assert me.json()["tenant"] == "tenant-a"
    assert table.invites[0]["redeemed_at"] is None, "a refused invite must stay redeemable"
    assert "alice" not in table.subject_tenants


def test_a_spent_invite_answers_410(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        token = _create(client, email="carol@example.test", tenant="tenant-b").json()["token"]
        carol = bearer(token_with_email("carol", "carol@example.test"))
        first = client.post("/api/v1/invites/redeem", json={"token": token}, headers=carol)
        dave = bearer(token_with_email("dave", "carol@example.test"))
        second = client.post("/api/v1/invites/redeem", json={"token": token}, headers=dave)

    assert first.status_code == 200
    assert second.status_code == 410 and second.json()["error"]["code"] == "invite_redeemed"
    assert "dave" not in table.subject_tenants


def test_an_expired_invite_answers_410(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        token = _create(client, email="carol@example.test", tenant="tenant-b").json()["token"]
        table.invites[0]["expires_at"] = datetime.now(timezone.utc) - timedelta(seconds=1)
        response = client.post("/api/v1/invites/redeem", json={"token": token}, headers=bearer(token_with_email("carol", "carol@example.test")))
        listed = client.get("/api/v1/invites", headers=bearer(token_with_email(SUPERADMIN, None)))

    assert response.status_code == 410 and response.json()["error"]["code"] == "invite_expired"
    assert "carol" not in table.subject_tenants
    assert listed.json()["invites"][0]["status"] == "expired"


def test_an_unknown_token_and_a_wrong_email_are_refused(monkeypatch, pool):
    table, get_pool = pool
    with client_for(monkeypatch) as client:
        _configure(monkeypatch, get_pool)
        token = _create(client, email="carol@example.test", tenant="tenant-b").json()["token"]
        unknown = client.post("/api/v1/invites/redeem", json={"token": "x" * 40}, headers=bearer(token_with_email("carol", None)))
        wrong = client.post("/api/v1/invites/redeem", json={"token": token}, headers=bearer(token_with_email("mallory", "mallory@example.test")))
        anonymous = client.post("/api/v1/invites/redeem", json={"token": token})

    assert unknown.status_code == 404
    assert wrong.status_code == 403 and wrong.json()["error"]["code"] == "invite_email_mismatch"
    assert anonymous.status_code == 401
    assert table.subject_tenants == {}


def test_redeem_requires_a_database(monkeypatch):
    with client_for(monkeypatch) as client:
        monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
        response = client.post("/api/v1/invites/redeem", json={"token": "x" * 40}, headers=bearer(token_with_email("alice", None)))

    assert response.status_code == 503, response.text
    assert response.json()["error"]["code"] == "database_unavailable"


def test_a_failing_binding_lookup_falls_back_to_the_environment_map(monkeypatch):
    class _Broken:
        async def fetchrow(self, *_a, **_k):
            raise RuntimeError("connection reset")

    async def get_pool():
        return _Broken()

    with client_for(monkeypatch) as client:
        monkeypatch.setattr(api_compat, "_get_pool", get_pool)
        monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
        response = client.get("/api/v1/me", headers=bearer(token_with_email("alice", None)))

    assert response.status_code == 200 and response.json()["tenant"] == "tenant-a"


def test_the_hint_cannot_be_used_to_borrow_a_binding(monkeypatch):
    """A forged unverified ``sub`` can at most warm the cache for a name the token does not carry."""
    monkeypatch.setattr(api_compat.settings, "api_subject_tenants", dict(SUBJECTS))
    assert api_compat.resolve_tenant({"sub": "alice"}, ("carol", "tenant-b")) == "tenant-a"
    assert api_compat.resolve_tenant({"sub": "alice"}, ("alice", "tenant-b")) == "tenant-b"
    assert invites.hash_token("abc") == hashlib.sha256(b"abc").hexdigest()
