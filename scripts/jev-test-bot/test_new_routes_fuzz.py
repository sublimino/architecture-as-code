"""test_new_routes_fuzz.py: Targeted chaos fuzzing and security boundary tests for new routes.

API surfaces covered:
  1. /api/v1/admin/users (GET, POST /invite, PATCH /{id}, DELETE /{id})
  2. /api/v1/features (GET)
  3. /api/v1/fleet/stun/{agentId} (POST)
  4. /api/v1/fleet/recover (POST)

Covers:
  - Superadmin and role-based authorization boundaries (401/403)
  - Malformed and boundary payload testing (empty, types, oversized, unexpected fields)
  - SQL injection and path traversal string injection in query parameters and paths
  - Unknown and non-existent entity lookups (404/400)
  - Idempotency and error payload structure assertions
  - Stochastic fuzzing with zero-500 invariants
"""

from __future__ import annotations

import json
import os
import random
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import pytest
from fastapi.testclient import TestClient

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
FE_SRC = os.path.join(REPO_ROOT, "d2-signalloom", "apps", "fe-signalloom", "src")
FE_TESTS = os.path.join(FE_SRC, "tests")
if FE_SRC not in sys.path:
    sys.path.insert(0, FE_SRC)
if FE_TESTS not in sys.path:
    sys.path.insert(0, FE_TESTS)

import api_compat
from api_compat import (
    Principal,
    authenticated_principal,
    invalidate_user_resolution_cache,
    settings,
)
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    invalidate_flag_cache,
)
from fuzz_api import ApiFuzzer, load_payloads
from main import app as fe_app
from platform_users import PlatformUser, _normalize_email
from superadmin import is_admin, is_superadmin
from conftest import (
    EAP_ALICE,
    EAP_BOB,
    EAP_OPERATOR,
    configure_eap_jwt,
    eap_token_for,
)

EAP_AUTHENTICATED = True

# ---------------------------------------------------------------------------
# Simulated Database and In-Memory Pool for fe-signalloom
# ---------------------------------------------------------------------------


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


class MockFeatureFlagDatabase:
    """In-memory store for public.tenant_feature_flags."""

    def __init__(self) -> None:
        self.flags: dict[tuple[str, str], dict[str, Any]] = {}

    def list_flags(self, tenant_id: str) -> list[dict[str, Any]]:
        results = [
            dict(row) for (t_id, _), row in self.flags.items()
            if t_id == tenant_id
        ]
        return sorted(results, key=lambda r: r["flag_key"])

    def set_flag(self, tenant_id: str, flag_key: str, enabled: bool, config: dict[str, Any] | None = None) -> dict[str, Any]:
        row = {
            "tenant_id": tenant_id,
            "flag_key": flag_key,
            "enabled": enabled,
            "config_json": config or {},
            "created_at": datetime.now(timezone.utc).isoformat(),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        self.flags[(tenant_id, flag_key)] = row
        return dict(row)


class UnifiedConnection:
    """Connection routing queries to MockUserDatabase and MockFeatureFlagDatabase."""

    def __init__(self, user_db: MockUserDatabase, flag_db: MockFeatureFlagDatabase) -> None:
        self.user_db = user_db
        self.flag_db = flag_db

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        if "FROM public.platform_users" in query:
            if "WHERE tenant_id = $1" in query:
                return self.user_db.list_users(tenant_id=args[0])
            return self.user_db.list_users(tenant_id=None)

        if "FROM public.tenant_feature_flags" in query:
            if "WHERE tenant_id = $1" in query:
                return self.flag_db.list_flags(tenant_id=args[0])
            return []

        if "FROM audit_events" in query or "FROM public.audit_events" in query:
            return [dict(e) for e in self.user_db.audit_events]

        return []

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        if "SELECT" in query and "FROM public.platform_users" in query:
            if "WHERE LOWER(email) = $1 AND tenant_id = $2" in query:
                return self.user_db.get_by_email(args[0], tenant_id=args[1])
            if "WHERE LOWER(email) = $1" in query:
                return self.user_db.get_by_email(args[0], tenant_id=None)
            if "WHERE id = $1 AND tenant_id = $2" in query:
                return self.user_db.get_by_id(args[0], tenant_id=args[1])
            if "WHERE id = $1" in query:
                return self.user_db.get_by_id(args[0], tenant_id=None)

        if "INSERT INTO public.platform_users" in query:
            user_id, tenant_id, email, display_name, role, status, is_superadmin, avatar_url, department, title = args
            return self.user_db.insert_user(
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

        if "UPDATE public.platform_users" in query:
            user_id = str(args[0])
            if "SET status = 'deactivated'" in query:
                return self.user_db.delete_user(user_id, soft=True)
            set_part = query.split("SET")[1].split("WHERE")[0]
            assignments = [item.strip() for item in set_part.split(",")]
            updates: dict[str, Any] = {}
            for item in assignments:
                if "=" in item and "$" in item:
                    col, param_str = item.split("=")
                    col = col.strip()
                    param_idx = int(param_str.strip().replace("$", ""))
                    updates[col] = args[param_idx - 1]
            return self.user_db.update_user(user_id, **updates)

        if "DELETE FROM public.platform_users" in query:
            user_id = str(args[0])
            return self.user_db.delete_user(user_id, soft=False)

        if "FROM public.tenant_feature_flags" in query:
            for flag in self.flag_db.list_flags(args[0]):
                if flag["flag_key"] == args[1]:
                    return flag
            return None

        if "FROM subject_tenants" in query:
            return None

        return None

    async def fetchval(self, query: str, *args: Any) -> Any:
        if "COUNT(*)::int" in query and "FROM public.platform_users" in query:
            if "AND id != $1" in query:
                return self.user_db.count_active_superadmins(exclude_user_id=args[0])
            return self.user_db.count_active_superadmins()
        return 1

    async def execute(self, query: str, *args: Any) -> str:
        if "INSERT INTO audit_events" in query or "INSERT INTO public.audit_events" in query:
            tenant_id = str(args[0]) if len(args) > 0 else "system"
            event_type = str(args[1]) if len(args) > 1 else "unknown"
            actor = str(args[4]) if len(args) > 4 else "system"
            detail_raw = args[5] if len(args) > 5 else "{}"
            detail = json.loads(detail_raw) if isinstance(detail_raw, str) else detail_raw
            self.user_db.record_audit(tenant_id, event_type, actor, detail)
            return "INSERT 0 1"
        return "OK"

    @asynccontextmanager
    async def transaction(self):
        yield self


class _ConnContext:
    def __init__(self, conn: UnifiedConnection) -> None:
        self.conn = conn

    async def __aenter__(self) -> UnifiedConnection:
        return self.conn

    async def __aexit__(self, *_args: Any) -> None:
        pass


class UnifiedPool:
    """Mock asyncpg pool servicing platform users, flags, and audit events."""

    serves_platform_users = True
    serves_subject_bindings = True

    def __init__(self, user_db: MockUserDatabase, flag_db: MockFeatureFlagDatabase) -> None:
        self.user_db = user_db
        self.flag_db = flag_db
        self.conn = UnifiedConnection(user_db, flag_db)

    def acquire(self) -> _ConnContext:
        return _ConnContext(self.conn)

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        return await self.conn.fetch(query, *args)

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        return await self.conn.fetchrow(query, *args)

    async def fetchval(self, query: str, *args: Any) -> Any:
        return await self.conn.fetchval(query, *args)

    async def execute(self, query: str, *args: Any) -> str:
        return await self.conn.execute(query, *args)


# ---------------------------------------------------------------------------
# Fleet Manager Process Fixture
# ---------------------------------------------------------------------------


@dataclass
class FleetServerContext:
    base_url: str
    dashboard_key: str
    operator_key: str
    readonly_key: str
    proc: subprocess.Popen


@pytest.fixture(scope="module")
def fleet_server():
    """Build and spawn a local fleet-manager instance with noop-test-only double."""
    bin_path = "/tmp/fleet-manager"
    if not (os.path.exists(bin_path) and os.access(bin_path, os.X_OK)):
        subprocess.run(
            ["go", "build", "-o", bin_path, "."],
            cwd=os.path.join(REPO_ROOT, "d2-signalloom", "apps", "fleet-manager"),
            check=True,
            capture_output=True,
        )

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write("""
aggregateRisk:
  ale: 847000
  var95: 1200000
  trend: up
  previousAle: 650000
agents:
  - id: agent-cardvault
    name: Card Vault
    type: data-vault
    team: platform
    trustProfile: high
    riskClass: high
    gracePeriod: 0h
    namespace: fe-signalloom-agents
    dependencies: []
  - id: agent-txn-pipeline
    name: Transaction Pipeline
    type: data-pipeline
    team: payments
    trustProfile: medium
    riskClass: medium
    gracePeriod: 72h
    namespace: fe-signalloom-agents
    dependencies: [agent-cardvault]
""")
        tmp_config = f.name

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    dashboard_key = "dashboard-key-12345678901234567890"
    operator_key = "operator-key-1234567890123456789012"
    readonly_key = "readonly-key-1234567890123456789012"

    env = os.environ.copy()
    env.update({
        "PORT": str(port),
        "FLEET_CONFIG": tmp_config,
        "STEP_DELAY_MS": "0",
        "FLEET_MANAGER_KEY_DASHBOARD": dashboard_key,
        "FLEET_MANAGER_KEY_DASHBOARD_SCOPES": "stun,deploy,scan,reset,read",
        "FLEET_MANAGER_KEY_OPERATOR": operator_key,
        "FLEET_MANAGER_KEY_OPERATOR_SCOPES": "recover,resume",
        "FLEET_MANAGER_KEY_READONLY": readonly_key,
        "FLEET_MANAGER_KEY_READONLY_SCOPES": "read",
    })

    proc = subprocess.Popen(
        [bin_path, "-fleet-client", "noop-test-only"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    base_url = f"http://127.0.0.1:{port}"
    started = False
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"{base_url}/health", timeout=1.0) as resp:
                if resp.status == 200:
                    started = True
                    break
        except Exception:
            time.sleep(0.05)

    if not started:
        proc.terminate()
        os.unlink(tmp_config)
        raise RuntimeError("Failed to start fleet-manager test server within timeout")

    ctx = FleetServerContext(
        base_url=base_url,
        dashboard_key=dashboard_key,
        operator_key=operator_key,
        readonly_key=readonly_key,
        proc=proc,
    )
    yield ctx

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
    if os.path.exists(tmp_config):
        os.unlink(tmp_config)


# ---------------------------------------------------------------------------
# In-Memory App Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def mock_dbs():
    user_db = MockUserDatabase()
    flag_db = MockFeatureFlagDatabase()
    return user_db, flag_db


@pytest.fixture
def unified_pool(mock_dbs):
    user_db, flag_db = mock_dbs
    pool = UnifiedPool(user_db, flag_db)
    from db.connection import set_pool_for_testing
    set_pool_for_testing(pool)
    fe_app.state.pool = pool
    api_compat._pool = pool
    yield pool
    set_pool_for_testing(None)
    fe_app.state.pool = None
    api_compat._pool = None


@pytest.fixture(autouse=True)
def _setup_jwt_auth(monkeypatch: pytest.MonkeyPatch):
    configure_eap_jwt(monkeypatch)


@pytest.fixture(autouse=True)
def _reset_caches():
    api_compat.invalidate_subject_binding()
    invalidate_user_resolution_cache()
    invalidate_flag_cache()
    yield
    api_compat.invalidate_subject_binding()
    invalidate_user_resolution_cache()
    invalidate_flag_cache()


def seed_test_roster(db: MockUserDatabase) -> dict[str, dict[str, Any]]:
    """Seed test directory platform users."""
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
    editor_a = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-a",
        email="editor-a@tenant-a.local",
        display_name="Tenant A Editor",
        role="editor",
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
    admin_b = db.insert_user(
        id=uuid.uuid4(),
        tenant_id="tenant-b",
        email="admin-b@tenant-b.local",
        display_name="Tenant B Admin",
        role="admin",
        status="active",
        is_superadmin=False,
    )
    return {
        "superadmin": superadmin,
        "admin_a": admin_a,
        "editor_a": editor_a,
        "viewer_a": viewer_a,
        "admin_b": admin_b,
    }


def make_client(email: str, subject: str = "sub_test") -> TestClient:
    token = eap_token_for(subject=subject, extra_claims={"email": email})
    return TestClient(fe_app, headers={"Authorization": f"Bearer {token}"})


# ===========================================================================
# 1. SUPERADMIN AND ROLE-BASED AUTHORIZATION BOUNDARIES
# ===========================================================================


def test_admin_users_unauthenticated_rejects_401(unified_pool: UnifiedPool) -> None:
    client = TestClient(fe_app)
    # Anonymous requests must receive 401 across all admin endpoints
    r1 = client.get("/api/v1/admin/users")
    assert r1.status_code == 401
    assert "error" in r1.json() or "detail" in r1.json()

    r2 = client.post("/api/v1/admin/users/invite", json={"email": "u@a.local", "display_name": "U"})
    assert r2.status_code == 401

    r3 = client.patch(f"/api/v1/admin/users/{uuid.uuid4()}", json={"display_name": "Updated"})
    assert r3.status_code == 401

    r4 = client.delete(f"/api/v1/admin/users/{uuid.uuid4()}")
    assert r4.status_code == 401


def test_admin_users_corrupted_bearer_rejects_401(unified_pool: UnifiedPool) -> None:
    for bad_header in [
        "Bearer ",
        "Bearer invalid-sig",
        "Bearer null\x00byte",
        "Basic dXNlcjpwYXNz",
        "Token corrupted",
    ]:
        client = TestClient(fe_app, headers={"Authorization": bad_header})
        resp = client.get("/api/v1/admin/users")
        assert resp.status_code == 401, f"Expected 401 for corrupted header: {bad_header}"


def test_admin_users_viewer_and_editor_denied_403(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)

    for role_key in ("viewer_a", "editor_a"):
        user = roster[role_key]
        client = make_client(user["email"], subject=f"{role_key}_sub")

        # GET
        r_get = client.get("/api/v1/admin/users")
        assert r_get.status_code == 403
        assert r_get.json()["error"]["code"] == "admin_required"

        # POST /invite
        r_post = client.post("/api/v1/admin/users/invite", json={"email": "new@a.local", "display_name": "New"})
        assert r_post.status_code == 403
        assert r_post.json()["error"]["code"] == "admin_required"

        # PATCH
        r_patch = client.patch(f"/api/v1/admin/users/{user['id']}", json={"display_name": "Changed"})
        assert r_patch.status_code == 403
        assert r_patch.json()["error"]["code"] == "admin_required"

        # DELETE
        r_del = client.delete(f"/api/v1/admin/users/{user['id']}")
        assert r_del.status_code == 403
        assert r_del.json()["error"]["code"] == "admin_required"


def test_admin_users_tenant_admin_scoped_to_own_tenant(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_a = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    # Tenant admin can list users in their own tenant
    resp = client_a.get("/api/v1/admin/users")
    assert resp.status_code == 200
    data = resp.json()
    assert all(u["tenant_id"] == "tenant-a" for u in data["users"])
    assert data["total"] == len(data["users"])


def test_admin_users_tenant_admin_cross_tenant_forbidden_403(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_a = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    # Cross-tenant list query forbidden
    r_list = client_a.get("/api/v1/admin/users?tenant_id=tenant-b")
    assert r_list.status_code == 403
    assert r_list.json()["error"]["code"] == "cross_tenant_forbidden"

    # Cross-tenant invite forbidden
    r_inv = client_a.post(
        "/api/v1/admin/users/invite",
        json={"email": "alien@b.local", "display_name": "Alien", "tenant_id": "tenant-b"},
    )
    assert r_inv.status_code == 403
    assert r_inv.json()["error"]["code"] == "cross_tenant_forbidden"

    # Cross-tenant patch forbidden
    r_patch = client_a.patch(f"/api/v1/admin/users/{roster['admin_b']['id']}", json={"display_name": "Hacked"})
    assert r_patch.status_code == 403
    assert r_patch.json()["error"]["code"] == "cross_tenant_forbidden"

    # Cross-tenant delete forbidden
    r_del = client_a.delete(f"/api/v1/admin/users/{roster['admin_b']['id']}")
    assert r_del.status_code == 403
    assert r_del.json()["error"]["code"] == "cross_tenant_forbidden"


def test_admin_users_tenant_admin_cannot_escalate_superadmin_403(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_a = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    # Granting superadmin on invite forbidden
    r_inv = client_a.post(
        "/api/v1/admin/users/invite",
        json={"email": "traitor@a.local", "display_name": "Traitor", "is_superadmin": True},
    )
    assert r_inv.status_code == 403
    assert r_inv.json()["error"]["code"] == "forbidden"

    # Modifying superadmin user forbidden
    r_mod = client_a.patch(f"/api/v1/admin/users/{roster['superadmin']['id']}", json={"display_name": "Renamed"})
    assert r_mod.status_code == 403
    assert r_mod.json()["error"]["code"] == "forbidden"

    # Elevating another user to superadmin forbidden
    r_up = client_a.patch(f"/api/v1/admin/users/{roster['viewer_a']['id']}", json={"is_superadmin": True})
    assert r_up.status_code == 403
    assert r_up.json()["error"]["code"] == "forbidden"

    # Deleting a superadmin forbidden
    r_del = client_a.delete(f"/api/v1/admin/users/{roster['superadmin']['id']}")
    assert r_del.status_code == 403
    assert r_del.json()["error"]["code"] == "forbidden"


def test_admin_users_superadmin_global_access(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    # Superadmin can query without tenant filter (returns all tenants)
    r_all = client_s.get("/api/v1/admin/users")
    assert r_all.status_code == 200
    data = r_all.json()
    tenants = {u["tenant_id"] for u in data["users"]}
    assert "tenant-a" in tenants and "tenant-b" in tenants

    # Superadmin can explicitly filter to foreign tenant
    r_b = client_s.get("/api/v1/admin/users?tenant_id=tenant-b")
    assert r_b.status_code == 200
    assert all(u["tenant_id"] == "tenant-b" for u in r_b.json()["users"])


def test_features_unauthenticated_rejects_401(unified_pool: UnifiedPool) -> None:
    client = TestClient(fe_app)
    resp = client.get("/api/v1/features")
    assert resp.status_code == 401


def test_features_viewer_and_editor_allowed_own_tenant(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_v = make_client(roster["viewer_a"]["email"], subject="viewer_sub")

    resp = client_v.get("/api/v1/features")
    assert resp.status_code == 200
    data = resp.json()
    assert data["tenant_id"] == "tenant-a"
    assert "flags" in data and isinstance(data["flags"], dict)
    assert "details" in data and isinstance(data["details"], dict)


def test_features_non_superadmin_cross_tenant_forbidden_403(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_a = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    resp = client_a.get("/api/v1/features?tenant_id=tenant-b")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "cross_tenant_forbidden"


def test_features_superadmin_cross_tenant_allowed_200(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    resp = client_s.get("/api/v1/features?tenant_id=tenant-b")
    assert resp.status_code == 200
    assert resp.json()["tenant_id"] == "tenant-b"


def test_fleet_recover_fe_signalloom_superadmin_gate(
    unified_pool: UnifiedPool,
    fleet_server: FleetServerContext,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    roster = seed_test_roster(unified_pool.user_db)

    # Anonymous -> 401
    anon_client = TestClient(fe_app)
    assert anon_client.post("/api/v1/fleet/recover").status_code == 401

    # Viewer -> 403
    v_client = make_client(roster["viewer_a"]["email"], subject="viewer_sub")
    assert v_client.post("/api/v1/fleet/recover").status_code == 403

    # Tenant admin -> 403 (superadmin required)
    a_client = make_client(roster["admin_a"]["email"], subject="admin_a_sub")
    assert a_client.post("/api/v1/fleet/recover").status_code == 403

    # Superadmin without operator key env -> 503
    monkeypatch.delenv("FLEET_MANAGER_OPERATOR_KEY", raising=False)
    s_client = make_client(roster["superadmin"]["email"], subject="super_sub")
    r_nokey = s_client.post("/api/v1/fleet/recover")
    assert r_nokey.status_code == 503
    assert r_nokey.json()["error"]["code"] == "fleet_operator_key_unavailable"


def test_fleet_manager_recover_auth_scopes(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/recover"

    # Missing Authorization -> 401
    req = urllib.request.Request(url, data=b"{}", method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(req)
    assert exc_info.value.code == 401

    # Key with insufficient scope (dashboard key lacks recover scope) -> 403
    headers = {"Authorization": f"Bearer {fleet_server.dashboard_key}", "Content-Type": "application/json"}
    req2 = urllib.request.Request(url, data=b"{}", headers=headers, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info2:
        urllib.request.urlopen(req2)
    assert exc_info2.value.code == 403


def test_fleet_manager_stun_auth_scopes(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/stun/agent-cardvault"

    # Missing Authorization -> 401
    req = urllib.request.Request(url, data=b'{"reason": "probe"}', headers={"Content-Type": "application/json"}, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(req)
    assert exc_info.value.code == 401

    # Readonly key lacking stun scope -> 403
    headers = {"Authorization": f"Bearer {fleet_server.readonly_key}", "Content-Type": "application/json"}
    req2 = urllib.request.Request(url, data=b'{"reason": "probe"}', headers=headers, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info2:
        urllib.request.urlopen(req2)
    assert exc_info2.value.code == 403


def test_fleet_manager_role_gate_requires_admin(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/stun/agent-cardvault"
    # Even with dashboard key, a caller role header specifying 'viewer' is rejected with 403
    headers = {
        "Authorization": f"Bearer {fleet_server.dashboard_key}",
        "Content-Type": "application/json",
        "X-User-Role": "viewer",
    }
    req = urllib.request.Request(url, data=b'{"reason": "probe"}', headers=headers, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(req)
    assert exc_info.value.code == 403


# ===========================================================================
# 2. MALFORMED AND BOUNDARY PAYLOAD TESTING
# ===========================================================================


def test_admin_users_invite_malformed_and_boundary_payloads(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    # Empty payload -> 422
    assert client_s.post("/api/v1/admin/users/invite", json={}).status_code == 422

    # Missing display_name -> 422
    assert client_s.post("/api/v1/admin/users/invite", json={"email": "test@a.local"}).status_code == 422

    # Missing email -> 422
    assert client_s.post("/api/v1/admin/users/invite", json={"display_name": "Name"}).status_code == 422

    # Invalid email string -> 422
    for bad_email in ["not-an-email", "@missinguser.com", "user name@spaces.com"]:
        r = client_s.post("/api/v1/admin/users/invite", json={"email": bad_email, "display_name": "Test"})
        assert r.status_code == 422

    # Oversized display_name (> 128 chars) -> 422
    oversized_name = "X" * 129
    r_name = client_s.post("/api/v1/admin/users/invite", json={"email": "ok@a.local", "display_name": oversized_name})
    assert r_name.status_code == 422

    # Oversized department (> 128 chars) -> 422
    r_dept = client_s.post("/api/v1/admin/users/invite", json={"email": "ok@a.local", "display_name": "Ok", "department": "D" * 129})
    assert r_dept.status_code == 422

    # Oversized title (> 128 chars) -> 422
    r_title = client_s.post("/api/v1/admin/users/invite", json={"email": "ok@a.local", "display_name": "Ok", "title": "T" * 129})
    assert r_title.status_code == 422

    # Oversized avatar_url (> 512 chars) -> 422
    r_avatar = client_s.post("/api/v1/admin/users/invite", json={"email": "ok@a.local", "display_name": "Ok", "avatar_url": "https://img.local/" + "A" * 512})
    assert r_avatar.status_code == 422

    # Forbidden unexpected fields (extra="forbid") -> 422
    r_extra = client_s.post("/api/v1/admin/users/invite", json={"email": "ok@a.local", "display_name": "Ok", "unexpected_field": "injected"})
    assert r_extra.status_code == 422

    # Invalid role enum -> 422
    r_role = client_s.post("/api/v1/admin/users/invite", json={"email": "ok@a.local", "display_name": "Ok", "role": "superuser"})
    assert r_role.status_code == 422

    # Wrong data types (integers or arrays where strings expected) -> 422
    r_type = client_s.post("/api/v1/admin/users/invite", json={"email": 12345, "display_name": ["Not", "A", "String"]})
    assert r_type.status_code == 422


def test_admin_users_update_malformed_and_boundary_payloads(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")
    uid = roster["viewer_a"]["id"]

    # Invalid status enum -> 422
    r_st = client_s.patch(f"/api/v1/admin/users/{uid}", json={"status": "banned"})
    assert r_st.status_code == 422

    # Invalid role enum -> 422
    r_ro = client_s.patch(f"/api/v1/admin/users/{uid}", json={"role": "root"})
    assert r_ro.status_code == 422

    # Unexpected fields -> 422
    r_ex = client_s.patch(f"/api/v1/admin/users/{uid}", json={"unknown_attr": "value"})
    assert r_ex.status_code == 422

    # Empty string display name (< 1 char) -> 422
    r_empty = client_s.patch(f"/api/v1/admin/users/{uid}", json={"display_name": ""})
    assert r_empty.status_code == 422


def test_features_unsupported_methods_return_405(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    assert client_s.post("/api/v1/features", json={}).status_code == 405
    assert client_s.put("/api/v1/features", json={}).status_code == 405
    assert client_s.delete("/api/v1/features").status_code == 405
    assert client_s.patch("/api/v1/features", json={}).status_code == 405


def test_fleet_stun_malformed_and_boundary_payloads(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/stun/agent-cardvault"
    auth = {"Authorization": f"Bearer {fleet_server.dashboard_key}", "Content-Type": "application/json"}

    # 1. Empty body -> 400
    req = urllib.request.Request(url, data=b"{}", headers=auth, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(req)
    assert exc.value.code == 400
    assert "reason is required" in exc.value.read().decode()

    # 2. Whitespace-only reason -> 400
    whitespace_body = json.dumps({"reason": "    "}).encode("utf-8")
    req2 = urllib.request.Request(url, data=whitespace_body, headers=auth, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc2:
        urllib.request.urlopen(req2)
    assert exc2.value.code == 400
    assert "reason is required" in exc2.value.read().decode()

    # 3. Contradictory agent_id in body vs path -> 400
    req3 = urllib.request.Request(
        url,
        data=b'{"agent_id": "agent-txn-pipeline", "reason": "valid reason"}',
        headers=auth,
        method="POST",
    )
    with pytest.raises(urllib.error.HTTPError) as exc3:
        urllib.request.urlopen(req3)
    assert exc3.value.code == 400
    assert "contradicts" in exc3.value.read().decode()

    # 4. Oversized body (> 4096 bytes) -> 400
    oversized = json.dumps({"reason": "A" * 5000}).encode("utf-8")
    req4 = urllib.request.Request(url, data=oversized, headers=auth, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc4:
        urllib.request.urlopen(req4)
    assert exc4.value.code == 400

    # 5. Non-POST methods -> 405
    for method in ("GET", "PUT", "DELETE"):
        req_m = urllib.request.Request(url, headers=auth, method=method)
        with pytest.raises(urllib.error.HTTPError) as exc_m:
            urllib.request.urlopen(req_m)
        assert exc_m.value.code == 405


def test_fleet_recover_malformed_and_boundary_payloads(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/recover"
    auth = {"Authorization": f"Bearer {fleet_server.operator_key}", "Content-Type": "application/json"}

    # 1. Invalid recover mode -> 400
    req = urllib.request.Request(url, data=b'{"mode": "destroy_all"}', headers=auth, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(req)
    assert exc.value.code == 400
    assert "unknown recover mode" in exc.value.read().decode()

    # 2. Non-POST methods -> 405
    for method in ("GET", "PUT", "DELETE"):
        req_m = urllib.request.Request(url, headers=auth, method=method)
        with pytest.raises(urllib.error.HTTPError) as exc_m:
            urllib.request.urlopen(req_m)
        assert exc_m.value.code == 405


# ===========================================================================
# 3. SQL INJECTION AND PATH TRAVERSAL STRING INJECTION
# ===========================================================================


SQLI_AND_TRAVERSAL_PAYLOADS = [
    "' OR '1'='1",
    "'; DROP TABLE platform_users; --",
    "1 UNION SELECT null, null, null--",
    "admin' --",
    "' or 1=1 or ''='",
    "../../../../etc/passwd",
    "..%2f..%2f..%2fetc%2fpasswd",
    "../../../../windows/win.ini",
    "%00../../etc/passwd",
    "/${7*7}",
    "<script>alert('xss')</script>",
    "{\"$gt\": \"\"}",
]


def test_features_sql_injection_and_path_traversal_in_tenant_id(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_a = make_client(roster["admin_a"]["email"], subject="admin_a_sub")
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    for payload in SQLI_AND_TRAVERSAL_PAYLOADS:
        encoded = urllib.parse.quote(payload)

        # 1. Non-superadmin cannot escape tenant confinement via query injection -> strictly 403
        r_tenant = client_a.get(f"/api/v1/features?tenant_id={encoded}")
        assert r_tenant.status_code == 403
        assert r_tenant.json()["error"]["code"] == "cross_tenant_forbidden"

        # 2. Superadmin evaluates injection string defensively -> 200 with system defaults, zero 500 crashes
        r_super = client_s.get(f"/api/v1/features?tenant_id={encoded}")
        assert r_super.status_code == 200
        data = r_super.json()
        assert data["tenant_id"] == payload
        assert "flags" in data
        assert "core_governance" in data["flags"]

    # Verify database table was not dropped by SQL injection attempts
    assert len(unified_pool.user_db.users) >= 5


def test_admin_users_sql_injection_and_path_traversal_in_query_params(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_a = make_client(roster["admin_a"]["email"], subject="admin_a_sub")
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    for payload in SQLI_AND_TRAVERSAL_PAYLOADS:
        encoded = urllib.parse.quote(payload)

        # Non-superadmin must be rejected with 403
        r_tenant = client_a.get(f"/api/v1/admin/users?tenant_id={encoded}")
        assert r_tenant.status_code == 403

        # Superadmin querying non-existent injected tenant receives empty user list with 200, zero 500s
        r_super = client_s.get(f"/api/v1/admin/users?tenant_id={encoded}")
        assert r_super.status_code == 200
        assert r_super.json()["total"] == 0
        assert r_super.json()["users"] == []


def test_admin_users_path_traversal_in_user_id(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")

    traversal_ids = [
        "../../etc/passwd",
        "..%2f..%2fetc%2fpasswd",
        "../../api/health",
        "%2e%2e%2f%2e%2e%2froot",
    ]

    for tid in traversal_ids:
        # Traversal in user ID path must be rejected with 404/400 and never leak filesystem
        r_patch = client_s.patch(f"/api/v1/admin/users/{tid}", json={"display_name": "Traverse"})
        assert r_patch.status_code in (404, 400, 422)

        r_del = client_s.delete(f"/api/v1/admin/users/{tid}")
        assert r_del.status_code in (404, 400, 422)


def test_fleet_stun_path_traversal_in_agent_id(fleet_server: FleetServerContext) -> None:
    auth = {"Authorization": f"Bearer {fleet_server.dashboard_key}", "Content-Type": "application/json"}
    traversal_agents = [
        "../recover",
        "../../reset",
        "agent-cardvault%2F..%2F..%2Freset",
        "..%2f..%2fetc%2fpasswd",
    ]

    for tagent in traversal_agents:
        url = f"{fleet_server.base_url}/api/v1/fleet/stun/{tagent}"
        req = urllib.request.Request(url, data=b'{"reason": "probe"}', headers=auth, method="POST")
        with pytest.raises(urllib.error.HTTPError) as exc:
            urllib.request.urlopen(req)
        # Fleet manager path resolution prevents traversal: returns 404 unknown agent, 400 bad request, or 307 redirect
        assert exc.value.code in (400, 404, 307)


# ===========================================================================
# 4. UNKNOWN / NON-EXISTENT ENTITY LOOKUPS
# ===========================================================================


def test_admin_users_unknown_user_lookup_returns_404(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client_s = make_client(roster["superadmin"]["email"], subject="super_sub")
    unknown_id = str(uuid.uuid4())

    r_patch = client_s.patch(f"/api/v1/admin/users/{unknown_id}", json={"display_name": "Ghost"})
    assert r_patch.status_code == 404
    assert r_patch.json()["error"]["code"] == "user_not_found"

    r_del = client_s.delete(f"/api/v1/admin/users/{unknown_id}")
    assert r_del.status_code == 404
    assert r_del.json()["error"]["code"] == "user_not_found"


def test_fleet_stun_unknown_agent_returns_404(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/stun/agent-phantom-9999"
    headers = {"Authorization": f"Bearer {fleet_server.dashboard_key}", "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=b'{"reason": "isolate rogue"}', headers=headers, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(req)
    assert exc.value.code == 404
    body = json.loads(exc.value.read().decode())
    assert body["error"] == "unknown agent"
    assert "tried" in body


def test_fleet_stun_empty_agent_id_returns_400(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/stun/"
    headers = {"Authorization": f"Bearer {fleet_server.dashboard_key}", "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=b'{"reason": "isolate"}', headers=headers, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(req)
    assert exc.value.code == 400
    assert "agent_id is required" in exc.value.read().decode()


# ===========================================================================
# 5. IDEMPOTENCY AND ERROR PAYLOAD STRUCTURE ASSERTIONS
# ===========================================================================


def test_features_read_idempotency(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    baseline = client.get("/api/v1/features").json()
    for _ in range(5):
        current = client.get("/api/v1/features").json()
        assert current == baseline


def test_admin_users_list_idempotency(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    baseline = client.get("/api/v1/admin/users").json()
    for _ in range(5):
        current = client.get("/api/v1/admin/users").json()
        assert current == baseline


def test_fleet_recover_idempotent_rejection_when_no_stunned_agents(fleet_server: FleetServerContext) -> None:
    url = f"{fleet_server.base_url}/api/v1/fleet/recover"
    headers = {"Authorization": f"Bearer {fleet_server.operator_key}", "Content-Type": "application/json"}

    for _ in range(3):
        req = urllib.request.Request(url, data=b"{}", headers=headers, method="POST")
        with pytest.raises(urllib.error.HTTPError) as exc:
            urllib.request.urlopen(req)
        assert exc.value.code == 400
        assert "no stunned agents to recover" in exc.value.read().decode()


def test_admin_users_duplicate_invite_conflict_idempotency(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    payload = {"email": "idempotent-test@tenant-a.local", "display_name": "Idempotent User"}
    # 1. First invite creates user
    r1 = client.post("/api/v1/admin/users/invite", json=payload)
    assert r1.status_code == 201

    # 2. Duplicate invite yields 409 Conflict without state mutation
    r2 = client.post("/api/v1/admin/users/invite", json=payload)
    assert r2.status_code == 409
    assert r2.json()["error"]["code"] == "user_already_exists"

    # 3. Third repeat still yields 409 Conflict
    r3 = client.post("/api/v1/admin/users/invite", json=payload)
    assert r3.status_code == 409


def test_last_superadmin_protection_invariant(unified_pool: UnifiedPool) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client = make_client(roster["superadmin"]["email"], subject="super_sub")
    super_id = roster["superadmin"]["id"]

    # Demoting last superadmin forbidden
    r_demote = client.patch(f"/api/v1/admin/users/{super_id}", json={"is_superadmin": False})
    assert r_demote.status_code == 400
    assert r_demote.json()["error"]["code"] == "last_superadmin_protected"

    # Suspending last superadmin forbidden
    r_suspend = client.patch(f"/api/v1/admin/users/{super_id}", json={"status": "suspended"})
    assert r_suspend.status_code == 400
    assert r_suspend.json()["error"]["code"] == "last_superadmin_protected"

    # Deactivating/deleting last superadmin forbidden
    r_delete = client.delete(f"/api/v1/admin/users/{super_id}")
    assert r_delete.status_code == 400
    assert r_delete.json()["error"]["code"] == "last_superadmin_protected"

    # Invariant holds: user is still active superadmin
    target = unified_pool.user_db.get_by_id(super_id)
    assert target is not None
    assert target["is_superadmin"] is True
    assert target["status"] == "active"


def test_error_payload_structure_invariants(unified_pool: UnifiedPool, fleet_server: FleetServerContext) -> None:
    roster = seed_test_roster(unified_pool.user_db)
    client = make_client(roster["admin_a"]["email"], subject="admin_a_sub")

    # fe-signalloom error response schema
    r = client.get("/api/v1/admin/users?tenant_id=foreign")
    data = r.json()
    assert "error" in data
    assert "code" in data["error"] and isinstance(data["error"]["code"], str)
    assert "message" in data["error"] and isinstance(data["error"]["message"], str)

    # fleet-manager error response schema
    url = f"{fleet_server.base_url}/api/v1/fleet/stun/"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {fleet_server.dashboard_key}"}, method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(req)
    fm_err = json.loads(exc.value.read().decode())
    assert "error" in fm_err and isinstance(fm_err["error"], str)


# ===========================================================================
# 6. STOCHASTIC CHAOS AND FUZZER INTEGRATION
# ===========================================================================


def test_stochastic_api_fuzzer_against_new_routes(fleet_server: FleetServerContext) -> None:
    """Run ApiFuzzer against the fleet-manager endpoints verifying zero-500 invariants."""
    fuzzer = ApiFuzzer(
        base_url=fleet_server.base_url,
        seed=20261010,
        total_requests=40,
        concurrency=6,
        timeout=4.0,
        endpoints=[
            "/health",
            "/api/v1/fleet/topology",
            "/api/v1/fleet/stun/agent-cardvault",
            "/api/v1/fleet/recover",
        ],
    )
    report = fuzzer.run()
    assert report["passed"] is True, f"Fuzzer detected defects: {report['defects']}"
    assert report["defects_count"] == 0
    assert report["total_requests"] == 40
    assert len(report["defects"]) == 0
