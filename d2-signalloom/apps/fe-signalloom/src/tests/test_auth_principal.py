"""Unit and integration tests for authenticated_principal dynamic user resolution.

Verifies:
1. Dynamic resolution of user record, tenant assignment, role, status, and is_superadmin from public.platform_users.
2. Immediate HTTP 403 rejection for suspended user accounts before route handler execution.
3. Case-insensitive email normalization stripping surrounding whitespace from Dex JWT claims.
4. Principal helper methods: is_admin(), is_superadmin(), has_tenant_access(tenant_id).
5. Fallback behavior when user is not present in platform_users or when database is unreachable.
6. Cryptographic token verification and 401 rejection for invalid/expired tokens before DB lookup.
7. Structured telemetry logging for identity resolution events.
"""
from __future__ import annotations

import logging
import socket
import time
import uuid
from types import SimpleNamespace
from typing import Annotated, Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import APIRouter, Depends
from fastapi.testclient import TestClient

import api_compat
from api_compat import (
    Principal,
    authenticated_principal,
    invalidate_user_resolution_cache,
    settings,
)
from db.connection import set_pool_for_testing

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-auth-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def make_token(
    subject: str = "alice",
    *,
    email: str | None = "alice@example.com",
    issuer: str = "https://issuer.test/dex",
    audience: str = "signalloom-api",
    authorized_party: str = "signalloom-dashboard",
    expires_in: int = 300,
    scope: str | None = None,
    identity_type: str | None = None,
) -> str:
    now = int(time.time())
    payload: dict[str, Any] = {
        "iss": issuer,
        "aud": audience,
        "iat": now,
        "nbf": now,
        "exp": now + expires_in,
        "azp": authorized_party,
        "sub": subject,
    }
    if email is not None:
        payload["email"] = email
    if scope is not None:
        payload["scope"] = scope
    if identity_type is not None:
        payload["identity_type"] = identity_type

    return jwt.encode(
        payload,
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-auth-key", "typ": "JWT"},
    )


class QueuedAuthPool:
    """Mock asyncpg connection pool with query recording and FIFO response queue."""

    serves_platform_users = True
    serves_subject_bindings = True

    def __init__(
        self,
        *,
        rows: list[dict[str, Any] | None] | None = None,
        subject_rows: list[dict[str, Any] | None] | None = None,
        lists: list[list[dict[str, Any]]] | None = None,
    ) -> None:
        self.rows = list(rows or [])
        self.subject_rows = list(subject_rows or [])
        self.lists = list(lists or [])
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    def _record(self, query: str, args: tuple[Any, ...]) -> None:
        self.statements.append((" ".join(query.split()), args))

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        self._record(query, args)
        if "platform_users" in query:
            return self.rows.pop(0) if self.rows else None
        if "subject_tenants" in query:
            return self.subject_rows.pop(0) if self.subject_rows else None
        return self.rows.pop(0) if self.rows else None

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        self._record(query, args)
        return self.lists.pop(0) if self.lists else []

    async def close(self) -> None:
        pass


@pytest.fixture(autouse=True)
def setup_auth_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    invalidate_user_resolution_cache()
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@localhost:5432/testdb")
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-demo", "legacy-sub": "tenant-legacy"})
    monkeypatch.setattr(settings, "api_superadmin_emails", {"superadmin-fallback@signalloom.local"})
    monkeypatch.setattr(settings, "api_superadmin_subjects", {"superadmin-sub"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: TestJWKClient())

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in auth tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(QueuedAuthPool())
    yield
    invalidate_user_resolution_cache()
    set_pool_for_testing(None)


# ---------------------------------------------------------------------------
# Test Cases: Superadmin Flag Resolution
# ---------------------------------------------------------------------------


def test_superadmin_flag_resolution() -> None:
    """Assert is_superadmin resolved from database record and helper methods reflect privileges."""
    user_id = uuid.uuid4()
    super_row = {
        "id": user_id,
        "tenant_id": "tenant-alpha",
        "email": "root@signalloom.local",
        "display_name": "Platform Root",
        "role": "admin",
        "status": "active",
        "is_superadmin": True,
        "avatar_url": None,
        "department": "Platform Security",
        "title": "Superadmin",
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
    }
    pool = QueuedAuthPool(rows=[super_row])
    set_pool_for_testing(pool)

    token = make_token("dex-root-sub", email="root@signalloom.local")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-superadmin")
    def get_principal_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {
            "tenant": p.tenant,
            "tenant_id": p.tenant_id,
            "subject": p.subject,
            "email": p.email,
            "role": p.role,
            "status": p.status,
            "is_superadmin": p.is_superadmin(),
            "is_admin": p.is_admin(),
            "has_access_alpha": p.has_tenant_access("tenant-alpha"),
            "has_access_beta": p.has_tenant_access("tenant-beta"),
            "user_id": p.user_id,
        }

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-superadmin", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["tenant"] == "tenant-alpha"
        assert data["tenant_id"] == "tenant-alpha"
        assert data["email"] == "root@signalloom.local"
        assert data["role"] == "admin"
        assert data["status"] == "active"
        assert data["is_superadmin"] is True
        assert data["is_admin"] is True
        assert data["has_access_alpha"] is True
        assert data["has_access_beta"] is True
        assert data["user_id"] == str(user_id)


# ---------------------------------------------------------------------------
# Test Cases: Suspended User Rejection (HTTP 403)
# ---------------------------------------------------------------------------


def test_suspended_user_403() -> None:
    """Assert suspended user status immediately raises HTTP 403 and halts handler execution."""
    user_id = uuid.uuid4()
    suspended_row = {
        "id": user_id,
        "tenant_id": "tenant-alpha",
        "email": "mallory@badactor.example",
        "display_name": "Mallory Suspended",
        "role": "viewer",
        "status": "suspended",
        "is_superadmin": False,
        "avatar_url": None,
        "department": None,
        "title": None,
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
    }
    pool = QueuedAuthPool(rows=[suspended_row])
    set_pool_for_testing(pool)

    token = make_token("mallory-sub", email="mallory@badactor.example")

    handler_reached = False
    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-suspended")
    def guarded_endpoint(
        _p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, str]:
        nonlocal handler_reached
        handler_reached = True
        return {"status": "ok"}

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-suspended", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 403
        assert handler_reached is False
        body = resp.json()
        assert body["error"]["code"] == "account_suspended"
        assert "suspended" in body["error"]["message"].lower()


# ---------------------------------------------------------------------------
# Test Cases: Tenant Admin Resolution
# ---------------------------------------------------------------------------


def test_tenant_admin_resolution() -> None:
    """Assert tenant admin role is assigned without superadmin bypass."""
    user_id = uuid.uuid4()
    admin_row = {
        "id": user_id,
        "tenant_id": "tenant-customer-a",
        "email": "admin@customer-a.example",
        "display_name": "Customer Admin",
        "role": "admin",
        "status": "active",
        "is_superadmin": False,
        "avatar_url": None,
        "department": "IT",
        "title": "Lead Admin",
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
    }
    pool = QueuedAuthPool(rows=[admin_row])
    set_pool_for_testing(pool)

    token = make_token("admin-sub", email="admin@customer-a.example")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-tenant-admin")
    def get_admin_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {
            "tenant": p.tenant,
            "role": p.role,
            "is_superadmin": p.is_superadmin(),
            "is_admin": p.is_admin(),
            "has_access_own": p.has_tenant_access("tenant-customer-a"),
            "has_access_other": p.has_tenant_access("tenant-customer-b"),
        }

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-tenant-admin", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["tenant"] == "tenant-customer-a"
        assert data["role"] == "admin"
        assert data["is_superadmin"] is False
        assert data["is_admin"] is True
        assert data["has_access_own"] is True
        assert data["has_access_other"] is False


# ---------------------------------------------------------------------------
# Test Cases: Regular User Resolution
# ---------------------------------------------------------------------------


def test_regular_user_resolution() -> None:
    """Assert regular viewer/editor role resolution and boundary isolation."""
    user_id = uuid.uuid4()
    user_row = {
        "id": user_id,
        "tenant_id": "tenant-customer-a",
        "email": "dev@customer-a.example",
        "display_name": "Customer Dev",
        "role": "editor",
        "status": "active",
        "is_superadmin": False,
        "avatar_url": None,
        "department": "Engineering",
        "title": "Software Engineer",
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
    }
    pool = QueuedAuthPool(rows=[user_row])
    set_pool_for_testing(pool)

    token = make_token("dev-sub", email="dev@customer-a.example")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-regular-user")
    def get_user_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {
            "tenant": p.tenant,
            "role": p.role,
            "is_superadmin": p.is_superadmin(),
            "is_admin": p.is_admin(),
            "has_access_own": p.has_tenant_access("tenant-customer-a"),
            "has_access_other": p.has_tenant_access("tenant-customer-b"),
        }

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-regular-user", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["tenant"] == "tenant-customer-a"
        assert data["role"] == "editor"
        assert data["is_superadmin"] is False
        assert data["is_admin"] is False
        assert data["has_access_own"] is True
        assert data["has_access_other"] is False


# ---------------------------------------------------------------------------
# Test Cases: Email Normalization
# ---------------------------------------------------------------------------


def test_email_normalization_case_and_whitespace() -> None:
    """Assert mixed-case and padded email claims match lowercase database rows."""
    user_id = uuid.uuid4()
    user_row = {
        "id": user_id,
        "tenant_id": "tenant-mixed",
        "email": "alice.smith@example.com",
        "display_name": "Alice Smith",
        "role": "editor",
        "status": "active",
        "is_superadmin": False,
        "avatar_url": None,
        "department": None,
        "title": None,
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
    }
    pool = QueuedAuthPool(rows=[user_row])
    set_pool_for_testing(pool)

    token = make_token("alice-sub", email="  Alice.Smith@EXAMPLE.COM  ")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-email-norm")
    def get_norm_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {"tenant": p.tenant, "email": p.email, "role": p.role}

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-email-norm", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["tenant"] == "tenant-mixed"
        assert data["role"] == "editor"
        assert any(
            "LOWER(email) = $1" in stmt[0] and stmt[1][0] == "alice.smith@example.com"
            for stmt in pool.statements
        )


# ---------------------------------------------------------------------------
# Test Cases: Fallback Behavior
# ---------------------------------------------------------------------------


def test_fallback_when_user_not_in_platform_users() -> None:
    """Assert unseeded users fall back to settings.api_subject_tenants with viewer role."""
    pool = QueuedAuthPool(rows=[None])
    set_pool_for_testing(pool)

    token = make_token("alice", email="unseeded@example.com")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-fallback")
    def get_fallback_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {
            "tenant": p.tenant,
            "role": p.role,
            "is_superadmin": p.is_superadmin(),
            "user_id": p.user_id,
        }

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-fallback", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["tenant"] == "tenant-demo"
        assert data["role"] == "viewer"
        assert data["is_superadmin"] is False
        assert data["user_id"] is None


def test_fallback_unbound_subject_rejected() -> None:
    """Assert unseeded users with no subject tenant mapping are rejected with 403."""
    pool = QueuedAuthPool(rows=[None])
    set_pool_for_testing(pool)

    token = make_token("unmapped-sub", email="unknown@example.com")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-unbound")
    def get_unbound_info(
        _p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {"status": "ok"}

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-unbound", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "tenant_forbidden"


def test_database_outage_graceful_fallback() -> None:
    """Assert database connection failure falls back gracefully to settings map."""

    class BrokenPool:
        serves_platform_users = True
        serves_subject_bindings = True

        async def fetchrow(self, _query: str, *_args: Any) -> Any:
            raise ConnectionError("Database disconnected")

        async def close(self) -> None:
            pass

    set_pool_for_testing(BrokenPool())

    token = make_token("alice", email="alice@example.com")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-db-outage")
    def get_outage_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {"tenant": p.tenant, "role": p.role}

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-db-outage", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200, resp.text
        assert resp.json()["tenant"] == "tenant-demo"


# ---------------------------------------------------------------------------
# Test Cases: Token Validation and Security Boundaries
# ---------------------------------------------------------------------------


def test_invalid_and_expired_tokens_rejected_401() -> None:
    """Assert token validity is enforced before database lookup."""
    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-token-validation")
    def get_protected_info(
        _p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {"status": "ok"}

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        # Missing auth header
        r1 = client.get("/test/auth-token-validation")
        assert r1.status_code == 401
        assert r1.json()["error"]["code"] == "authentication_required"

        # Malformed bearer
        r2 = client.get("/test/auth-token-validation", headers={"Authorization": "Basic dXNlcjpwYXNz"})
        assert r2.status_code == 401
        assert r2.json()["error"]["code"] == "invalid_token"

        # Expired token
        expired_token = make_token("alice", expires_in=-10)
        r3 = client.get("/test/auth-token-validation", headers={"Authorization": f"Bearer {expired_token}"})
        assert r3.status_code == 401
        assert r3.json()["error"]["code"] == "invalid_token"


def test_host_credential_scope_restricted() -> None:
    """Assert host credentials with audit-upload-only scope are rejected from control plane APIs."""
    host_token = make_token("host-sensor-1", scope="audit-upload-only", identity_type="external-host")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-host-restricted")
    def get_control_plane(
        _p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {"status": "ok"}

    app.include_router(test_router)

    with TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-host-restricted", headers={"Authorization": f"Bearer {host_token}"})
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "host_credential_scope_restricted"


# ---------------------------------------------------------------------------
# Test Cases: Principal Helper Methods
# ---------------------------------------------------------------------------


def test_principal_helper_methods_matrix() -> None:
    """Assert is_admin(), is_superadmin(), and has_tenant_access() across role matrix."""
    # 1. Platform superadmin
    superadmin_p = Principal(
        tenant="tenant-alpha",
        subject="superadmin-1",
        email="super@example.com",
        role="admin",
        is_superadmin=True,
    )
    assert superadmin_p.is_superadmin() is True
    assert superadmin_p.is_admin() is True
    assert superadmin_p.has_tenant_access("tenant-alpha") is True
    assert superadmin_p.has_tenant_access("tenant-beta") is True
    assert superadmin_p.tenant_id == "tenant-alpha"
    assert superadmin_p.actor == "super@example.com"

    # 2. Tenant admin
    tenant_admin_p = Principal(
        tenant="tenant-alpha",
        subject="admin-1",
        email="admin@alpha.example",
        role="admin",
        is_superadmin=False,
    )
    assert tenant_admin_p.is_superadmin() is False
    assert tenant_admin_p.is_admin() is True
    assert tenant_admin_p.has_tenant_access("tenant-alpha") is True
    assert tenant_admin_p.has_tenant_access("tenant-beta") is False

    # 3. Regular editor
    editor_p = Principal(
        tenant="tenant-alpha",
        subject="editor-1",
        email="editor@alpha.example",
        role="editor",
        is_superadmin=False,
    )
    assert editor_p.is_superadmin() is False
    assert editor_p.is_admin() is False
    assert editor_p.has_tenant_access("tenant-alpha") is True
    assert editor_p.has_tenant_access("tenant-beta") is False

    # 4. Regular viewer
    viewer_p = Principal(
        tenant="tenant-alpha",
        subject="viewer-1",
        email=None,
        role="viewer",
        is_superadmin=False,
    )
    assert viewer_p.is_superadmin() is False
    assert viewer_p.is_admin() is False
    assert viewer_p.has_tenant_access("tenant-alpha") is True
    assert viewer_p.has_tenant_access("tenant-beta") is False
    assert viewer_p.actor == "viewer-1"


# ---------------------------------------------------------------------------
# Test Cases: Structured Logging Telemetry
# ---------------------------------------------------------------------------


def test_structured_logging_telemetry(caplog: pytest.LogCaptureFixture) -> None:
    """Assert structured logging captures identity resolution events with actor, tenant, and role."""
    user_id = uuid.uuid4()
    user_row = {
        "id": user_id,
        "tenant_id": "tenant-logged",
        "email": "logger@logged.example",
        "display_name": "Logger User",
        "role": "admin",
        "status": "active",
        "is_superadmin": False,
        "avatar_url": None,
        "department": None,
        "title": None,
        "last_login_at": None,
        "created_at": None,
        "updated_at": None,
    }
    pool = QueuedAuthPool(rows=[user_row])
    set_pool_for_testing(pool)

    token = make_token("logged-sub", email="logger@logged.example")

    from main import app

    test_router = APIRouter()

    @test_router.get("/test/auth-logging")
    def get_logging_info(
        p: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, Any]:
        return {"status": "ok"}

    app.include_router(test_router)

    with caplog.at_level(logging.INFO), TestClient(app, raise_server_exceptions=False) as client:
        resp = client.get("/test/auth-logging", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200

    log_messages = [record.message for record in caplog.records]
    assert any(
        "authenticated principal resolved: actor=logger@logged.example, tenant=tenant-logged, role=admin, is_superadmin=False"
        in msg
        for msg in log_messages
    )
