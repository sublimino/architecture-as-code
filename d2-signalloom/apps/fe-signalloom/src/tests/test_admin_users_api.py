"""Contract and authorization test suite for Signal Loom Admin Users API.

Tests:
1. Authorization matrix:
   - Anonymous requests rejected with 401
   - Viewer and Editor roles rejected with 403 (admin_required)
   - Tenant Admin permitted for their own tenant
   - Superadmin permitted globally across all tenants
2. Strict multi-tenant isolation:
   - Non-superadmin cannot query other tenants (403 cross_tenant_forbidden)
   - Non-superadmin cannot invite into other tenants (403 cross_tenant_forbidden)
   - Non-superadmin cannot grant superadmin privilege (403 forbidden)
   - Non-superadmin cannot patch or delete other tenants' users (403 cross_tenant_forbidden)
   - Non-superadmin cannot modify superadmin users (403 forbidden)
3. User lifecycle CRUD operations:
   - GET /api/v1/admin/users: list tenant users or global users
   - POST /api/v1/admin/users/invite: provision/invite user, return 201
   - POST /api/v1/admin/users/invite: reject duplicate email with 409 Conflict
   - PATCH /api/v1/admin/users/{user_id}: update display_name, role, status, email
   - PATCH /api/v1/admin/users/{user_id}: reject email conflict across users (409)
   - DELETE /api/v1/admin/users/{user_id}: soft delete / deactivate user
   - Protection of the last active platform superadmin (400)
4. Audit event logging:
   - Emit user.invited, user.updated, user.role_updated, user.status_updated, user.deleted
5. OpenAPI documentation exposure.
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

import pytest
from api.admin_users import (
    InviteUserRequest,
    UpdateUserRequest,
    UserResponse,
    UsersListResponse,
    install_admin_users_api,
    require_admin_or_superadmin,
)
from api_compat import (
    Principal,
    authenticated_principal,
    invalidate_user_resolution_cache,
)
from conftest import eap_token_for
from db.connection import set_pool_for_testing
from fastapi.testclient import TestClient
from main import app as main_app
from platform_users import PlatformUser, _normalize_email
from superadmin import is_admin, is_superadmin

EAP_AUTHENTICATED = True


# ==============================================================================
# Simulated In-Memory Database & FakePool
# ==============================================================================


class MockUserDatabase:
    """In-memory store simulating public.platform_users and public.audit_events."""

    def __init__(self) -> None:
        self.users: dict[str, dict[str, Any]] = {}
        self.audit_events: list[dict[str, Any]] = []

    def insert_user(
        self,
        id: str | uuid.UUID,
        tenant_id: str,
        email: str,
        display_name: str,
        role: str = "viewer",
        status: str = "active",
        is_superadmin: bool = False,
        avatar_url: str | None = None,
        department: str | None = None,
        title: str | None = None,
    ) -> dict[str, Any]:
        uid = str(id)
        norm_email = _normalize_email(email)
        now = datetime.now(timezone.utc).isoformat()
        row = {
            "id": uid,
            "tenant_id": tenant_id,
            "email": norm_email,
            "display_name": display_name,
            "role": role,
            "status": status,
            "is_superadmin": is_superadmin,
            "avatar_url": avatar_url,
            "department": department,
            "title": title,
            "last_login_at": None,
            "created_at": now,
            "updated_at": now,
        }
        self.users[uid] = row
        return dict(row)

    def get_by_id(self, user_id: str | uuid.UUID, tenant_id: str | None = None) -> dict[str, Any] | None:
        uid = str(user_id)
        row = self.users.get(uid)
        if row is None:
            return None
        if tenant_id is not None and row["tenant_id"] != tenant_id:
            return None
        return dict(row)

    def get_by_email(self, email: str, tenant_id: str | None = None) -> dict[str, Any] | None:
        norm = _normalize_email(email)
        candidates = [
            r for r in self.users.values()
            if r["email"].lower() == norm.lower()
            and (tenant_id is None or r["tenant_id"] == tenant_id)
        ]
        if not candidates:
            return None
        # Sort superadmins first, then created_at
        candidates.sort(key=lambda r: (not r["is_superadmin"], r["created_at"]))
        return dict(candidates[0])

    def list_users(self, tenant_id: str | None = None) -> list[dict[str, Any]]:
        results = [
            dict(r) for r in self.users.values()
            if tenant_id is None or r["tenant_id"] == tenant_id
        ]
        return sorted(results, key=lambda r: (r["created_at"], r["id"]))

    def update_user(self, user_id: str | uuid.UUID, **kwargs: Any) -> dict[str, Any] | None:
        uid = str(user_id)
        if uid not in self.users:
            return None
        row = self.users[uid]
        for k, v in kwargs.items():
            if v is not None:
                if k == "email":
                    row[k] = _normalize_email(v)
                else:
                    row[k] = v
        row["updated_at"] = datetime.now(timezone.utc).isoformat()
        return dict(row)

    def delete_user(self, user_id: str | uuid.UUID, soft: bool = True) -> dict[str, Any] | None:
        uid = str(user_id)
        if uid not in self.users:
            return None
        if soft:
            self.users[uid]["status"] = "deactivated"
            self.users[uid]["updated_at"] = datetime.now(timezone.utc).isoformat()
            return dict(self.users[uid])
        else:
            return self.users.pop(uid)

    def count_active_superadmins(self, exclude_user_id: str | uuid.UUID | None = None) -> int:
        ex_uid = str(exclude_user_id) if exclude_user_id else None
        return sum(
            1 for r in self.users.values()
            if r["is_superadmin"] is True
            and r["status"] == "active"
            and (ex_uid is None or r["id"] != ex_uid)
        )

    def record_audit(self, tenant_id: str, event_type: str, actor: str, detail: dict[str, Any]) -> None:
        self.audit_events.append({
            "tenant_id": tenant_id,
            "event_type": event_type,
            "actor": actor,
            "detail": detail,
            "created_at": datetime.now(timezone.utc).isoformat(),
        })


class FakeAdminConnection:
    """Simulated asyncpg connection routing queries to MockUserDatabase."""

    def __init__(self, db: MockUserDatabase) -> None:
        self.db = db

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        if "FROM public.platform_users" in query:
            if "WHERE tenant_id = $1" in query:
                return self.db.list_users(tenant_id=args[0])
            return self.db.list_users(tenant_id=None)
        if "FROM audit_events" in query:
            return [dict(e) for e in self.db.audit_events]
        raise NotImplementedError(f"Unhandled fetch query: {query}")

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        if "SELECT" in query and "FROM public.platform_users" in query:
            if "WHERE LOWER(email) = $1 AND tenant_id = $2" in query:
                return self.db.get_by_email(args[0], tenant_id=args[1])
            if "WHERE LOWER(email) = $1" in query:
                return self.db.get_by_email(args[0], tenant_id=None)
            if "WHERE id = $1 AND tenant_id = $2" in query:
                return self.db.get_by_id(args[0], tenant_id=args[1])
            if "WHERE id = $1" in query:
                return self.db.get_by_id(args[0], tenant_id=None)

        if "INSERT INTO public.platform_users" in query:
            user_id, tenant_id, email, display_name, role, status, is_superadmin, avatar_url, department, title = args
            return self.db.insert_user(
                id=user_id,
                tenant_id=tenant_id,
                email=email,
                display_name=display_name,
                role=role,
                status=status,
                is_superadmin=is_superadmin,
                avatar_url=avatar_url,
                department=department,
                title=title,
            )

        if "FROM subject_tenants" in query:
            return None

        if "UPDATE public.platform_users" in query:
            user_id = str(args[0])
            if "SET status = 'deactivated'" in query:
                return self.db.delete_user(user_id, soft=True)

            # Parse SET clause accurately matching col = $N
            set_part = query.split("SET")[1].split("WHERE")[0]
            assignments = [item.strip() for item in set_part.split(",")]
            updates: dict[str, Any] = {}
            for item in assignments:
                if "=" in item and "$" in item:
                    col, param_str = item.split("=")
                    col = col.strip()
                    param_idx = int(param_str.strip().replace("$", ""))
                    updates[col] = args[param_idx - 1]
            return self.db.update_user(user_id, **updates)

        if "DELETE FROM public.platform_users" in query:
            user_id = str(args[0])
            return self.db.delete_user(user_id, soft=False)

        raise NotImplementedError(f"Unhandled fetchrow query: {query}")

    async def fetchval(self, query: str, *args: Any) -> Any:
        if "COUNT(*)::int" in query and "FROM public.platform_users" in query:
            if "AND id != $1" in query:
                return self.db.count_active_superadmins(exclude_user_id=args[0])
            return self.db.count_active_superadmins()
        return 1

    async def execute(self, query: str, *args: Any) -> str:
        if "INSERT INTO audit_events" in query or "INSERT INTO public.audit_events" in query:
            tenant_id, event_type, agent_uuid, agent_name, actor, detail_json = args
            detail = json.loads(detail_json) if isinstance(detail_json, str) else detail_json
            self.db.record_audit(tenant_id, event_type, actor, detail)
            return "INSERT 0 1"
        return "OK"


class FakeAdminPool:
    """Fake asyncpg Pool managing simulated users and audit events."""

    serves_platform_users = True
    serves_subject_bindings = True

    def __init__(self, db: MockUserDatabase | None = None) -> None:
        self.db = db or MockUserDatabase()

    def acquire(self) -> _AdminConnContext:
        return _AdminConnContext(FakeAdminConnection(self.db))

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        conn = FakeAdminConnection(self.db)
        return await conn.fetch(query, *args)

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        conn = FakeAdminConnection(self.db)
        return await conn.fetchrow(query, *args)

    async def fetchval(self, query: str, *args: Any) -> Any:
        conn = FakeAdminConnection(self.db)
        return await conn.fetchval(query, *args)

    async def execute(self, query: str, *args: Any) -> str:
        conn = FakeAdminConnection(self.db)
        return await conn.execute(query, *args)


class _AdminConnContext:
    def __init__(self, conn: FakeAdminConnection) -> None:
        self.conn = conn

    async def __aenter__(self) -> FakeAdminConnection:
        return self.conn

    async def __aexit__(self, *exc: Any) -> None:
        pass


@pytest.fixture
def mock_db() -> MockUserDatabase:
    return MockUserDatabase()


@pytest.fixture
def fake_pool(mock_db: MockUserDatabase) -> FakeAdminPool:
    pool = FakeAdminPool(mock_db)
    set_pool_for_testing(pool)
    main_app.state.pool = pool
    yield pool
    set_pool_for_testing(None)
    main_app.state.pool = None


@pytest.fixture(autouse=True)
def _clear_cache() -> None:
    invalidate_user_resolution_cache()
    yield
    invalidate_user_resolution_cache()


def auth_client(email: str, subject: str = "test_sub") -> TestClient:
    """Create a TestClient with a signed RS256 Bearer token for the given email/subject."""
    token = eap_token_for(subject=subject, extra_claims={"email": email})
    return TestClient(main_app, headers={"Authorization": f"Bearer {token}"})


# ==============================================================================
# Helper User Fixtures
# ==============================================================================


def seed_standard_users(db: MockUserDatabase) -> dict[str, dict[str, Any]]:
    """Seed standard test users across tenant-a and tenant-b."""
    superadmin = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-a",
        email="superadmin@signalloom.local",
        display_name="Global SuperAdmin",
        role="admin",
        status="active",
        is_superadmin=True,
    )
    admin_a = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-a",
        email="admin-a@tenant-a.local",
        display_name="Tenant A Admin",
        role="admin",
        status="active",
        is_superadmin=False,
    )
    viewer_a = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-a",
        email="viewer-a@tenant-a.local",
        display_name="Tenant A Viewer",
        role="viewer",
        status="active",
        is_superadmin=False,
    )
    editor_a = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-a",
        email="editor-a@tenant-a.local",
        display_name="Tenant A Editor",
        role="editor",
        status="active",
        is_superadmin=False,
    )
    user_b = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-b",
        email="user-b@tenant-b.local",
        display_name="Tenant B User",
        role="admin",
        status="active",
        is_superadmin=False,
    )
    return {
        "superadmin": superadmin,
        "admin_a": admin_a,
        "viewer_a": viewer_a,
        "editor_a": editor_a,
        "user_b": user_b,
    }


# ==============================================================================
# 1. Unauthenticated & Authorization Matrix Tests
# ==============================================================================


def test_admin_users_unauthenticated_returns_401(fake_pool: FakeAdminPool) -> None:
    """Anonymous requests must be rejected with 401."""
    client = TestClient(main_app)
    assert client.get("/api/v1/admin/users").status_code == 401
    assert client.post("/api/v1/admin/users/invite", json={"email": "a@b.com", "display_name": "A"}).status_code == 401
    assert client.patch(f"/api/v1/admin/users/{uuid.uuid4()}", json={"display_name": "B"}).status_code == 401
    assert client.delete(f"/api/v1/admin/users/{uuid.uuid4()}").status_code == 401


def test_viewer_access_denied(fake_pool: FakeAdminPool) -> None:
    """Callers with role 'viewer' must be rejected with HTTP 403 (admin_required)."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["viewer_a"]["email"], subject="viewer_sub")

    # GET
    resp = client.get("/api/v1/admin/users")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "admin_required"

    # POST /invite
    resp = client.post("/api/v1/admin/users/invite", json={"email": "new@a.local", "display_name": "New"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "admin_required"

    # PATCH
    resp = client.patch(f"/api/v1/admin/users/{users['admin_a']['id']}", json={"display_name": "Updated"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "admin_required"

    # DELETE
    resp = client.delete(f"/api/v1/admin/users/{users['admin_a']['id']}")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "admin_required"


def test_editor_access_denied(fake_pool: FakeAdminPool) -> None:
    """Callers with role 'editor' must be rejected with HTTP 403 (admin_required)."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["editor_a"]["email"], subject="editor_sub")

    resp = client.get("/api/v1/admin/users")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "admin_required"


def test_tenant_admin_allowed_own_tenant(fake_pool: FakeAdminPool) -> None:
    """Tenant administrators must be allowed to manage users in their own tenant."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    # GET /api/v1/admin/users
    resp = client.get("/api/v1/admin/users")
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data["users"], list)
    # Tenant admin only receives tenant-a users
    assert all(u["tenant_id"] == "tenant-a" for u in data["users"])
    assert data["total"] == len(data["users"])


def test_superadmin_allowed_cross_tenant(fake_pool: FakeAdminPool) -> None:
    """Superadmins must be allowed to list users across all tenants."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["superadmin"]["email"], subject="superadmin_sub")

    resp = client.get("/api/v1/admin/users")
    assert resp.status_code == 200
    data = resp.json()
    tenant_ids = {u["tenant_id"] for u in data["users"]}
    assert "tenant-a" in tenant_ids
    assert "tenant-b" in tenant_ids


# ==============================================================================
# 2. Strict Cross-Tenant Isolation Tests
# ==============================================================================


def test_tenant_admin_cross_tenant_forbidden(fake_pool: FakeAdminPool) -> None:
    """Tenant admin querying with foreign ?tenant_id= must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    resp = client.get("/api/v1/admin/users?tenant_id=tenant-b")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "cross_tenant_forbidden"


def test_tenant_admin_cannot_invite_into_foreign_tenant(fake_pool: FakeAdminPool) -> None:
    """Tenant admin specifying foreign tenant_id on invite must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    resp = client.post(
        "/api/v1/admin/users/invite",
        json={"email": "target@tenant-b.local", "display_name": "Target", "tenant_id": "tenant-b"},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "cross_tenant_forbidden"


def test_tenant_admin_cannot_grant_superadmin(fake_pool: FakeAdminPool) -> None:
    """Tenant admin attempting to set is_superadmin=True must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    resp = client.post(
        "/api/v1/admin/users/invite",
        json={"email": "escalate@tenant-a.local", "display_name": "Escalate", "is_superadmin": True},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"


def test_tenant_admin_cannot_patch_foreign_user(fake_pool: FakeAdminPool) -> None:
    """Tenant admin patching user in another tenant must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    foreign_user_id = users["user_b"]["id"]
    resp = client.patch(f"/api/v1/admin/users/{foreign_user_id}", json={"display_name": "Hacked"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "cross_tenant_forbidden"


def test_tenant_admin_cannot_patch_superadmin(fake_pool: FakeAdminPool) -> None:
    """Tenant admin patching a superadmin account must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    superadmin_id = users["superadmin"]["id"]
    resp = client.patch(f"/api/v1/admin/users/{superadmin_id}", json={"role": "viewer"})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"


def test_tenant_admin_cannot_modify_superadmin_flag(fake_pool: FakeAdminPool) -> None:
    """Tenant admin attempting to set is_superadmin on a user must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    target_id = users["viewer_a"]["id"]
    resp = client.patch(f"/api/v1/admin/users/{target_id}", json={"is_superadmin": True})
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"


def test_tenant_admin_cannot_delete_foreign_user(fake_pool: FakeAdminPool) -> None:
    """Tenant admin deleting user in another tenant must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    foreign_user_id = users["user_b"]["id"]
    resp = client.delete(f"/api/v1/admin/users/{foreign_user_id}")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "cross_tenant_forbidden"


def test_tenant_admin_cannot_delete_superadmin(fake_pool: FakeAdminPool) -> None:
    """Tenant admin deleting a superadmin must be rejected with 403."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    superadmin_id = users["superadmin"]["id"]
    resp = client.delete(f"/api/v1/admin/users/{superadmin_id}")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden"


# ==============================================================================
# 3. User Lifecycle CRUD Operations & Edge Cases
# ==============================================================================


def test_invite_user_success_and_duplicate_conflict(fake_pool: FakeAdminPool) -> None:
    """Invite user provisions record with status 'invited' and prevents duplicate email."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    # 1. Successful invitation
    resp = client.post(
        "/api/v1/admin/users/invite",
        json={
            "email": "invited.engineer@tenant-a.local",
            "display_name": "Invited Engineer",
            "role": "editor",
            "department": "Platform Security",
            "title": "Security Lead",
        },
    )
    assert resp.status_code == 201
    created = resp.json()
    assert created["email"] == "invited.engineer@tenant-a.local"
    assert created["display_name"] == "Invited Engineer"
    assert created["role"] == "editor"
    assert created["status"] == "invited"
    assert created["tenant_id"] == "tenant-a"
    assert created["department"] == "Platform Security"
    assert created["title"] == "Security Lead"
    assert created["is_superadmin"] is False

    # 2. Duplicate email returns 409 Conflict
    dup_resp = client.post(
        "/api/v1/admin/users/invite",
        json={
            "email": "invited.engineer@tenant-a.local",
            "display_name": "Duplicate Engineer",
        },
    )
    assert dup_resp.status_code == 409
    assert dup_resp.json()["error"]["code"] == "user_already_exists"


def test_update_user_fields_and_email_conflict(fake_pool: FakeAdminPool) -> None:
    """Update user mutates properties and validates email conflict."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    target_id = users["viewer_a"]["id"]

    # 1. Update display_name, role, status
    resp = client.patch(
        f"/api/v1/admin/users/{target_id}",
        json={
            "display_name": "Promoted Lead",
            "role": "editor",
            "status": "active",
            "department": "Infrastructure",
        },
    )
    assert resp.status_code == 200
    updated = resp.json()
    assert updated["display_name"] == "Promoted Lead"
    assert updated["role"] == "editor"
    assert updated["status"] == "active"
    assert updated["department"] == "Infrastructure"

    # 2. Update email to conflict with existing user -> 409
    conflict_resp = client.patch(
        f"/api/v1/admin/users/{target_id}",
        json={"email": users["admin_a"]["email"]},
    )
    assert conflict_resp.status_code == 409
    assert conflict_resp.json()["error"]["code"] == "email_conflict"


def test_soft_delete_user(fake_pool: FakeAdminPool) -> None:
    """DELETE /api/v1/admin/users/{user_id} soft deletes user setting status to deactivated."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    target_id = users["viewer_a"]["id"]
    resp = client.delete(f"/api/v1/admin/users/{target_id}")
    assert resp.status_code == 200
    deleted = resp.json()
    assert deleted["id"] == str(target_id)
    assert deleted["status"] == "deactivated"

    # Verify user record in DB is deactivated
    user_in_db = fake_pool.db.get_by_id(target_id)
    assert user_in_db is not None
    assert user_in_db["status"] == "deactivated"


def test_not_found_user_endpoints(fake_pool: FakeAdminPool) -> None:
    """Non-existent user IDs return 404."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    missing_id = str(uuid.uuid4())
    assert client.patch(f"/api/v1/admin/users/{missing_id}", json={"display_name": "None"}).status_code == 404
    assert client.delete(f"/api/v1/admin/users/{missing_id}").status_code == 404


# ==============================================================================
# 4. Last Active Superadmin Protection Tests
# ==============================================================================


def test_protect_last_active_superadmin_demotion(fake_pool: FakeAdminPool) -> None:
    """Attempting to demote the sole active platform superadmin returns 400."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["superadmin"]["email"], subject="superadmin_sub")

    superadmin_id = users["superadmin"]["id"]

    # Attempt to unset is_superadmin
    resp = client.patch(f"/api/v1/admin/users/{superadmin_id}", json={"is_superadmin": False})
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "last_superadmin_protected"


def test_protect_last_active_superadmin_suspension(fake_pool: FakeAdminPool) -> None:
    """Attempting to suspend or deactivate the sole active superadmin returns 400."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["superadmin"]["email"], subject="superadmin_sub")

    superadmin_id = users["superadmin"]["id"]

    # Attempt to suspend
    resp = client.patch(f"/api/v1/admin/users/{superadmin_id}", json={"status": "suspended"})
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "last_superadmin_protected"

    # Attempt to delete
    resp = client.delete(f"/api/v1/admin/users/{superadmin_id}")
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "last_superadmin_protected"


def test_superadmin_demotion_allowed_when_second_active_exists(fake_pool: FakeAdminPool) -> None:
    """When multiple active superadmins exist, one can be demoted."""
    users = seed_standard_users(fake_pool.db)
    # Add second superadmin
    second_super = fake_pool.db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-a",
        email="second.super@signalloom.local",
        display_name="Second Superadmin",
        role="admin",
        status="active",
        is_superadmin=True,
    )

    client = auth_client(users["superadmin"]["email"], subject="superadmin_sub")

    # Demote second superadmin
    resp = client.patch(f"/api/v1/admin/users/{second_super['id']}", json={"is_superadmin": False})
    assert resp.status_code == 200
    assert resp.json()["is_superadmin"] is False


# ==============================================================================
# 5. Audit Event Emission Tests
# ==============================================================================


def test_audit_event_emitted(fake_pool: FakeAdminPool) -> None:
    """Lifecycle actions (invite, update, role change, status change, delete) emit audit events."""
    users = seed_standard_users(fake_pool.db)
    client = auth_client(users["admin_a"]["email"], subject="admin_sub")

    # 1. Invite user -> user.invited
    resp = client.post(
        "/api/v1/admin/users/invite",
        json={"email": "audit.test@tenant-a.local", "display_name": "Audit Test", "role": "viewer"},
    )
    assert resp.status_code == 201
    created_id = resp.json()["id"]

    invite_events = [e for e in fake_pool.db.audit_events if e["event_type"] == "user.invited"]
    assert len(invite_events) >= 1
    assert invite_events[-1]["detail"]["email"] == "audit.test@tenant-a.local"
    assert invite_events[-1]["actor"] == users["admin_a"]["email"]

    # 2. Patch user role -> user.role_updated and user.updated
    resp = client.patch(f"/api/v1/admin/users/{created_id}", json={"role": "editor"})
    assert resp.status_code == 200

    role_events = [e for e in fake_pool.db.audit_events if e["event_type"] == "user.role_updated"]
    assert len(role_events) >= 1
    assert role_events[-1]["detail"]["new_role"] == "editor"

    # 3. Patch user status -> user.status_updated
    resp = client.patch(f"/api/v1/admin/users/{created_id}", json={"status": "suspended"})
    assert resp.status_code == 200

    status_events = [e for e in fake_pool.db.audit_events if e["event_type"] == "user.status_updated"]
    assert len(status_events) >= 1
    assert status_events[-1]["detail"]["new_status"] == "suspended"

    # 4. Delete user -> user.deleted
    resp = client.delete(f"/api/v1/admin/users/{created_id}")
    assert resp.status_code == 200

    delete_events = [e for e in fake_pool.db.audit_events if e["event_type"] == "user.deleted"]
    assert len(delete_events) >= 1
    assert delete_events[-1]["detail"]["user_id"] == str(created_id)


# ==============================================================================
# 6. OpenAPI Documentation Schema Verification
# ==============================================================================


def test_openapi_schema_contains_admin_users_endpoints() -> None:
    """OpenAPI schema must describe /api/v1/admin/users routes and schemas."""
    schema = main_app.openapi()
    paths = schema.get("paths", {})

    assert "/api/v1/admin/users" in paths
    assert "get" in paths["/api/v1/admin/users"]

    assert "/api/v1/admin/users/invite" in paths
    assert "post" in paths["/api/v1/admin/users/invite"]

    assert "/api/v1/admin/users/{user_id}" in paths
    assert "patch" in paths["/api/v1/admin/users/{user_id}"]
    assert "delete" in paths["/api/v1/admin/users/{user_id}"]
