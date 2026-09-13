"""AMXO-P1-1 attributable operator identity lifecycle contracts."""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import uuid

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError

import api_compat
import operator_identity
from db.connection import set_pool_for_testing
from main import app


MIGRATION = Path(__file__).resolve().parent.parent / "db" / "migrations" / "038_operator_identities.sql"
USER_ID = uuid.UUID("a1000000-0000-0000-0000-000000000001")
IDENTITY_ID = uuid.UUID("b1000000-0000-0000-0000-000000000001")
TARGET_USER_ID = uuid.UUID("a1000000-0000-0000-0000-000000000002")
TARGET_IDENTITY_ID = uuid.UUID("b1000000-0000-0000-0000-000000000002")
NOW = datetime(2026, 9, 12, 18, 30, tzinfo=timezone.utc)


@pytest.fixture(autouse=True)
def configured_issuer(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(api_compat.settings, "api_jwt_issuer", "https://issuer.test/dex")


def principal(subject: str = "alice", email: str | None = "alice@agentmaxxing.example") -> api_compat.Principal:
    return api_compat.Principal(tenant="tenant-agentmaxxing", subject=subject, email=email)


def identity_row(
    *,
    identity_kind: str = "individual",
    identity_status: str = "active",
    user_status: str = "active",
    role: str = "editor",
    subject: str = "alice",
    user_id: uuid.UUID = USER_ID,
    identity_id: uuid.UUID = IDENTITY_ID,
) -> dict[str, Any]:
    removed = identity_status == "removed"
    return {
        "identity_id": identity_id,
        "platform_user_id": user_id,
        "tenant_id": "tenant-agentmaxxing",
        "issuer": "https://issuer.test/dex",
        "subject": subject,
        "identity_kind": identity_kind,
        "identity_status": identity_status,
        "email": "alice@agentmaxxing.example",
        "display_name": "Alice Operator",
        "role": role,
        "user_status": user_status,
        "last_login_at": NOW,
        "created_at": NOW,
        "removed_at": NOW if removed else None,
        "removed_by_user_id": USER_ID if removed else None,
        "removal_reason": "Employment ended" if removed else None,
    }


class QueuedPool:
    """Minimal asyncpg twin with explicit ordered results."""

    def __init__(
        self,
        *,
        rows: list[dict[str, Any] | None] | None = None,
        values: list[Any] | None = None,
        lists: list[list[dict[str, Any]]] | None = None,
    ) -> None:
        self.rows = list(rows or [])
        self.values = list(values or [])
        self.lists = list(lists or [])
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    def _record(self, query: str, args: tuple[Any, ...]) -> None:
        self.statements.append((" ".join(query.split()), args))

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        self._record(query, args)
        return self.rows.pop(0) if self.rows else None

    async def fetchval(self, query: str, *args: Any) -> Any:
        self._record(query, args)
        return self.values.pop(0) if self.values else 0

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        self._record(query, args)
        return self.lists.pop(0) if self.lists else []

    async def execute(self, query: str, *args: Any) -> str:
        self._record(query, args)
        return "UPDATE 1"

    async def close(self) -> None:
        return None

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


def install_pool(monkeypatch: pytest.MonkeyPatch, pool: QueuedPool) -> None:
    async def require_pool(_what: str) -> QueuedPool:
        return pool

    async def get_pool() -> QueuedPool:
        return pool

    monkeypatch.setattr(api_compat, "_require_pool", require_pool)
    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    monkeypatch.setattr(api_compat.settings, "api_jwt_issuer", "https://issuer.test/dex")


def error_from(awaitable: Any) -> api_compat.APIError:
    with pytest.raises(api_compat.APIError) as caught:
        asyncio.run(awaitable)
    return caught.value


def test_operator_identity_migration_is_additive_and_attributable() -> None:
    sql = MIGRATION.read_text()
    assert "CREATE TABLE IF NOT EXISTS public.operator_identities" in sql
    assert "REFERENCES public.platform_users (id, tenant_id)" in sql
    assert "UNIQUE (issuer, subject)" in sql
    assert "identity_kind = 'individual'" in sql
    assert "ADD COLUMN IF NOT EXISTS actor_user_id UUID" in sql
    assert "ADD COLUMN IF NOT EXISTS actor_issuer TEXT" in sql
    assert "ADD COLUMN IF NOT EXISTS actor_subject TEXT" in sql
    assert "FOREIGN KEY (actor_user_id, tenant_id)" in sql
    assert "REFERENCES public.platform_users (id, tenant_id)" in sql
    assert "UPDATE public.platform_users" not in sql
    assert "DROP TABLE" not in sql


def test_operator_identity_migration_enforces_coherent_removal_metadata() -> None:
    sql = MIGRATION.read_text()
    assert "operator_identities_removal_check" in sql
    assert "status = 'active'" in sql
    assert "removed_at IS NULL" in sql
    assert "status = 'removed'" in sql
    assert "removed_by_user_id IS NOT NULL" in sql
    assert "removal_reason IS NOT NULL" in sql


def test_operator_identity_migration_scopes_constraint_introspection_to_public() -> None:
    sql = MIGRATION.read_text()
    assert sql.count("conrelid = 'public.audit_events'::regclass") >= 4


def test_operator_identity_create_model_normalizes_individual_email() -> None:
    model = operator_identity.OperatorIdentityCreateRequest(
        provider_subject="alice",
        email=" Alice@AgentMaxxing.Example ",
        display_name="Alice Operator",
        role="editor",
    )
    assert model.email == "alice@agentmaxxing.example"
    assert model.identity_kind == "individual"


@pytest.mark.parametrize("kind", ["shared", "anonymous"])
def test_operator_identity_create_model_rejects_nonindividual_credentials(kind: str) -> None:
    with pytest.raises(ValidationError):
        operator_identity.OperatorIdentityCreateRequest(
            provider_subject="shared-account",
            email="shared@agentmaxxing.example",
            display_name="Shared Account",
            role="editor",
            identity_kind=kind,
        )


def test_operator_identity_create_model_rejects_tenant_spoofing() -> None:
    with pytest.raises(ValidationError):
        operator_identity.OperatorIdentityCreateRequest.model_validate(
            {
                "provider_subject": "alice",
                "email": "alice@agentmaxxing.example",
                "display_name": "Alice Operator",
                "role": "editor",
                "tenant_id": "victim-tenant",
            }
        )


def test_operator_identity_removal_requires_a_meaningful_reason() -> None:
    with pytest.raises(ValidationError):
        operator_identity.OperatorIdentityRemovalRequest(reason="  ")


def test_operator_identity_active_record_resolves_to_immutable_user_id() -> None:
    resolved = operator_identity.operator_from_row(principal(), identity_row())
    assert resolved.user_id == USER_ID
    assert resolved.identity_id == IDENTITY_ID
    assert resolved.tenant_id == "tenant-agentmaxxing"
    assert resolved.role == "editor"


def test_operator_identity_shared_record_is_rejected_fail_closed() -> None:
    with pytest.raises(api_compat.APIError) as caught:
        operator_identity.operator_from_row(
            principal("legacy-shared", "shared@agentmaxxing.example"),
            identity_row(identity_kind="shared", subject="legacy-shared"),
        )
    assert caught.value.status_code == 403
    assert caught.value.code == "shared_identity_forbidden"


def test_operator_identity_removed_record_is_rejected_fail_closed() -> None:
    with pytest.raises(api_compat.APIError) as caught:
        operator_identity.operator_from_row(principal(), identity_row(identity_status="removed"))
    assert caught.value.status_code == 403
    assert caught.value.code == "operator_removed"


def test_operator_identity_missing_subject_is_rejected_as_anonymous() -> None:
    with pytest.raises(api_compat.APIError) as caught:
        operator_identity.operator_from_row(principal(subject=""), identity_row(subject=""))
    assert caught.value.status_code == 401
    assert caught.value.code == "anonymous_operator_forbidden"


def test_operator_identity_cross_tenant_row_is_rejected() -> None:
    row = identity_row()
    row["tenant_id"] = "victim-tenant"
    with pytest.raises(api_compat.APIError) as caught:
        operator_identity.operator_from_row(principal(), row)
    assert caught.value.status_code == 403
    assert caught.value.code == "operator_tenant_mismatch"


def test_operator_identity_sign_in_records_user_id_and_server_audit(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row()], values=[NOW])
    install_pool(monkeypatch, pool)

    response = asyncio.run(operator_identity.operator_session(principal()))

    assert response.operator.id == str(IDENTITY_ID)
    assert response.operator.platform_user_id == str(USER_ID)
    assert response.operator.last_login_at == api_compat._ts(NOW)
    audit = [(sql, args) for sql, args in pool.statements if "INSERT INTO public.audit_events" in sql]
    assert len(audit) == 1
    assert USER_ID in audit[0][1]
    assert "operator.sign_in_succeeded" in audit[0][1]
    assert all("timestamp" not in sql.partition("VALUES")[0].lower() for sql, _ in audit)


def test_operator_identity_removed_sign_in_is_denied_and_audited(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row(identity_status="removed")])
    install_pool(monkeypatch, pool)

    error = error_from(operator_identity.operator_session(principal()))

    assert error.code == "operator_removed"
    audit = [(sql, args) for sql, args in pool.statements if "INSERT INTO public.audit_events" in sql]
    assert len(audit) == 1
    assert USER_ID in audit[0][1]
    assert "operator.sign_in_denied" in audit[0][1]


def test_operator_identity_shared_sign_in_is_denied_and_audited(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row(identity_kind="shared")])
    install_pool(monkeypatch, pool)

    error = error_from(operator_identity.operator_session(principal()))

    assert error.code == "shared_identity_forbidden"
    assert any("operator.sign_in_denied" in args for _, args in pool.statements)


def test_operator_identity_removal_is_atomic_and_attributable(monkeypatch: pytest.MonkeyPatch) -> None:
    admin = identity_row(role="admin")
    target = identity_row(
        user_id=TARGET_USER_ID,
        identity_id=TARGET_IDENTITY_ID,
        subject="bob",
    )
    removed = dict(target, identity_status="removed", user_status="deactivated", removed_at=NOW,
                   removed_by_user_id=USER_ID, removal_reason="Partner access withdrawn")
    pool = QueuedPool(rows=[admin, target, removed])
    install_pool(monkeypatch, pool)

    response = asyncio.run(
        operator_identity.remove_operator_identity(
            TARGET_IDENTITY_ID,
            operator_identity.OperatorIdentityRemovalRequest(reason="Partner access withdrawn"),
            principal(),
        )
    )

    assert response.operator.status == "removed"
    assert response.operator.removed_by_user_id == str(USER_ID)
    assert "pg_advisory_xact_lock" in pool.statements[0][0]
    assert any("UPDATE public.operator_identities" in sql for sql, _ in pool.statements)
    audit = [(sql, args) for sql, args in pool.statements if "INSERT INTO public.audit_events" in sql]
    assert len(audit) == 1
    assert USER_ID in audit[0][1]
    assert str(TARGET_USER_ID) in audit[0][1][-1]


def test_operator_identity_repeated_removal_is_idempotent(monkeypatch: pytest.MonkeyPatch) -> None:
    admin = identity_row(role="admin")
    removed = identity_row(
        user_id=TARGET_USER_ID,
        identity_id=TARGET_IDENTITY_ID,
        subject="bob",
        identity_status="removed",
        user_status="deactivated",
    )
    pool = QueuedPool(rows=[admin, removed])
    install_pool(monkeypatch, pool)

    response = asyncio.run(
        operator_identity.remove_operator_identity(
            TARGET_IDENTITY_ID,
            operator_identity.OperatorIdentityRemovalRequest(reason="Repeated request"),
            principal(),
        )
    )

    assert response.changed is False
    assert not any("UPDATE public.operator_identities" in sql for sql, _ in pool.statements)
    assert not any("INSERT INTO public.audit_events" in sql for sql, _ in pool.statements)


def test_operator_identity_last_admin_cannot_be_removed(monkeypatch: pytest.MonkeyPatch) -> None:
    admin = identity_row(role="admin")
    pool = QueuedPool(rows=[admin, admin], values=[0])
    install_pool(monkeypatch, pool)

    error = error_from(
        operator_identity.remove_operator_identity(
            IDENTITY_ID,
            operator_identity.OperatorIdentityRemovalRequest(reason="Remove final administrator"),
            principal(),
        )
    )

    assert error.status_code == 409
    assert error.code == "last_operator_admin"
    assert not any("UPDATE public.operator_identities" in sql for sql, _ in pool.statements)


def test_operator_identity_editor_cannot_administer_users(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row(role="editor")])
    install_pool(monkeypatch, pool)

    error = error_from(operator_identity.list_operator_identities(principal()))

    assert error.status_code == 403
    assert error.code == "operator_admin_required"


def test_operator_identity_authorization_matrix_is_explicit() -> None:
    assert operator_identity.AUTHORIZATION_MATRIX == {
        "admin": frozenset({"operator:create", "operator:list", "operator:remove", "operator:sign-in"}),
        "editor": frozenset({"operator:sign-in"}),
        "viewer": frozenset({"operator:sign-in"}),
    }


def test_operator_identity_routes_are_mounted_once() -> None:
    expected = {
        ("GET", "/api/operator-identities/session"),
        ("POST", "/api/operator-identities"),
        ("GET", "/api/operator-identities"),
        ("POST", "/api/operator-identities/{identity_id}/remove"),
    }
    registered = [
        (method.upper(), path)
        for path, operations in app.openapi()["paths"].items()
        if path.startswith("/api/operator-identities")
        for method in operations
    ]
    assert set(registered) == expected
    assert len(registered) == len(expected)


def test_operator_identity_creation_is_tenant_derived_and_audited(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    admin = identity_row(role="admin")
    created = identity_row(
        user_id=TARGET_USER_ID,
        identity_id=TARGET_IDENTITY_ID,
        subject="bob",
    )
    created["email"] = "bob@agentmaxxing.example"
    created["display_name"] = "Bob Operator"
    pool = QueuedPool(
        rows=[admin, {"id": TARGET_USER_ID}, {"id": TARGET_IDENTITY_ID}, created],
        values=[USER_ID],
    )
    install_pool(monkeypatch, pool)

    response = asyncio.run(
        operator_identity.create_operator_identity(
            operator_identity.OperatorIdentityCreateRequest(
                provider_subject="bob",
                email="bob@agentmaxxing.example",
                display_name="Bob Operator",
                role="editor",
            ),
            principal(),
        )
    )

    assert response.tenant_id == "tenant-agentmaxxing"
    assert "pg_advisory_xact_lock" in pool.statements[0][0]
    inserts = [(sql, args) for sql, args in pool.statements if sql.startswith("INSERT")]
    assert any("public.platform_users" in sql for sql, _ in inserts)
    assert any("public.operator_identities" in sql for sql, _ in inserts)
    assert all("victim-tenant" not in args for _, args in inserts)
    assert any("operator.created" in args for _, args in inserts)


def test_operator_identity_creation_rejects_an_ordinary_operator(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    pool = QueuedPool(rows=[identity_row(role="editor")])
    install_pool(monkeypatch, pool)

    error = error_from(
        operator_identity.create_operator_identity(
            operator_identity.OperatorIdentityCreateRequest(
                provider_subject="bob",
                email="bob@agentmaxxing.example",
                display_name="Bob Operator",
            ),
            principal(),
        )
    )

    assert error.code == "operator_admin_required"
    assert not any(sql.startswith("INSERT") for sql, _ in pool.statements)


def test_operator_identity_initial_admin_bootstrap_is_self_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    bootstrap = principal("bootstrap", "bootstrap@agentmaxxing.example")
    created = identity_row(
        role="admin",
        subject="bootstrap",
        user_id=TARGET_USER_ID,
        identity_id=TARGET_IDENTITY_ID,
    )
    created["email"] = "bootstrap@agentmaxxing.example"
    pool = QueuedPool(
        rows=[None, {"id": TARGET_USER_ID}, {"id": TARGET_IDENTITY_ID}, created],
        values=[0, TARGET_USER_ID],
    )
    identifiers = iter([TARGET_USER_ID, TARGET_IDENTITY_ID])
    install_pool(monkeypatch, pool)
    monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {"bootstrap"})
    monkeypatch.setattr(operator_identity.uuid, "uuid4", lambda: next(identifiers))

    response = asyncio.run(
        operator_identity.create_operator_identity(
            operator_identity.OperatorIdentityCreateRequest(
                provider_subject="bootstrap",
                email="bootstrap@agentmaxxing.example",
                display_name="Bootstrap Operator",
                role="admin",
            ),
            bootstrap,
        )
    )

    assert response.role == "admin"
    assert response.provider_subject == "bootstrap"
    assert any("operator.created" in args for _, args in pool.statements)


def test_operator_identity_initial_admin_cannot_bootstrap_another_person(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    bootstrap = principal("bootstrap", "bootstrap@agentmaxxing.example")
    pool = QueuedPool(rows=[None], values=[0])
    install_pool(monkeypatch, pool)
    monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {"bootstrap"})

    error = error_from(
        operator_identity.create_operator_identity(
            operator_identity.OperatorIdentityCreateRequest(
                provider_subject="someone-else",
                email="someone-else@agentmaxxing.example",
                display_name="Someone Else",
                role="admin",
            ),
            bootstrap,
        )
    )

    assert error.code == "operator_bootstrap_self_only"
    assert not any(sql.startswith("INSERT") for sql, _ in pool.statements)


def test_operator_identity_listing_is_scoped_to_the_authenticated_tenant(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    pool = QueuedPool(rows=[identity_row(role="admin")], lists=[[identity_row()]])
    install_pool(monkeypatch, pool)

    response = asyncio.run(operator_identity.list_operator_identities(principal()))

    assert response.total == 1
    list_queries = [(sql, args) for sql, args in pool.statements if "ORDER BY oi.created_at" in sql]
    assert list_queries
    assert "oi.tenant_id = $1" in list_queries[0][0]
    assert list_queries[0][1] == ("tenant-agentmaxxing",)


def test_operator_identity_strict_tenant_gate_blocks_removed_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    pool = QueuedPool(rows=[identity_row(identity_status="removed")])
    install_pool(monkeypatch, pool)
    monkeypatch.setattr(
        api_compat.settings,
        "api_attributable_operator_tenants",
        {"tenant-agentmaxxing"},
    )

    error = error_from(operator_identity.enforce_strict_operator_tenant(principal()))

    assert error.code == "operator_removed"


def test_operator_identity_nonpartner_tenant_avoids_identity_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    called = False

    async def unexpected(_principal: api_compat.Principal) -> None:
        nonlocal called
        called = True

    monkeypatch.setattr(operator_identity, "ensure_active_operator", unexpected)
    monkeypatch.setattr(
        api_compat.settings,
        "api_attributable_operator_tenants",
        {"tenant-agentmaxxing"},
    )
    demo = api_compat.Principal(tenant="tenant-demo", subject="demo-user", email=None)

    asyncio.run(operator_identity.enforce_strict_operator_tenant(demo))

    assert called is False


def test_operator_identity_lifecycle_rejects_unmanaged_tenant_before_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def unexpected(_what: str) -> None:
        raise AssertionError("unmanaged lifecycle request reached the identity database")

    monkeypatch.setattr(api_compat, "_require_pool", unexpected)
    unmanaged = api_compat.Principal(tenant="tenant-demo", subject="demo-user", email=None)

    error = error_from(operator_identity.operator_session(unmanaged))

    assert error.code == "operator_tenant_not_managed"


def test_operator_identity_openapi_declares_reachable_error_statuses() -> None:
    isolated = FastAPI()
    isolated.include_router(operator_identity.router)
    paths = isolated.openapi()["paths"]

    session_responses = paths["/api/operator-identities/session"]["get"]["responses"]
    removal_responses = paths["/api/operator-identities/{identity_id}/remove"]["post"]["responses"]
    assert set(session_responses) >= {
        "200", "401", "403", "503"
    }
    assert set(removal_responses) >= {
        "200", "401", "403", "404", "409", "503"
    }
    for responses in (session_responses, removal_responses):
        for status, response in responses.items():
            if status in {"401", "403", "404", "409", "503"}:
                assert response["content"]["application/json"]["schema"] == {
                    "$ref": "#/components/schemas/ErrorResponse"
                }


def test_operator_identity_session_route_rejects_anonymous_http_request() -> None:
    isolated = FastAPI()
    api_compat.install_api_exception_handlers(isolated)
    isolated.include_router(operator_identity.router)

    with TestClient(isolated, raise_server_exceptions=False) as client:
        response = client.get("/api/operator-identities/session")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"


def test_operator_identity_strict_gate_blocks_other_partner_api_routes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    pool = QueuedPool(rows=[identity_row(identity_status="removed")])
    install_pool(monkeypatch, pool)
    monkeypatch.setattr(
        api_compat.settings,
        "api_attributable_operator_tenants",
        {"tenant-agentmaxxing"},
    )
    app.dependency_overrides[api_compat.authenticated_principal] = principal
    set_pool_for_testing(pool)
    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            response = client.get("/api/agents")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "operator_removed"


def test_platform_users_module_exports_operator_identity_symbols() -> None:
    import platform_users

    assert platform_users.router is operator_identity.router
    assert platform_users.AUTHORIZATION_MATRIX == operator_identity.AUTHORIZATION_MATRIX
    assert platform_users.OperatorIdentityCreateRequest is operator_identity.OperatorIdentityCreateRequest
    assert platform_users.OperatorIdentityRemovalRequest is operator_identity.OperatorIdentityRemovalRequest
    assert platform_users.OperatorIdentityResponse is operator_identity.OperatorIdentityResponse
    assert platform_users.OperatorIdentitiesResponse is operator_identity.OperatorIdentitiesResponse
    assert platform_users.OperatorSessionResponse is operator_identity.OperatorSessionResponse
    assert platform_users.OperatorRemovalResponse is operator_identity.OperatorRemovalResponse
    assert platform_users.OperatorPrincipal is operator_identity.OperatorPrincipal


def test_operator_rejection_of_shared_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row(identity_kind="shared")])
    install_pool(monkeypatch, pool)

    error = error_from(operator_identity.operator_session(principal()))
    assert error.status_code == 403
    assert error.code == "shared_identity_forbidden"


def test_operator_rejection_of_removed_operators(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row(identity_status="removed")])
    install_pool(monkeypatch, pool)

    error = error_from(operator_identity.operator_session(principal()))
    assert error.status_code == 403
    assert error.code == "operator_removed"


def test_operator_rejection_of_anonymous_principals() -> None:
    with pytest.raises(api_compat.APIError) as caught:
        operator_identity.operator_from_row(principal(subject=""), identity_row(subject=""))
    assert caught.value.status_code == 401
    assert caught.value.code == "anonymous_operator_forbidden"


def test_operator_rejection_of_cross_tenant_access() -> None:
    row = identity_row()
    row["tenant_id"] = "victim-tenant"
    with pytest.raises(api_compat.APIError) as caught:
        operator_identity.operator_from_row(principal(), row)
    assert caught.value.status_code == 403
    assert caught.value.code == "operator_tenant_mismatch"


def test_operator_rejection_of_unmanaged_tenants(monkeypatch: pytest.MonkeyPatch) -> None:
    unmanaged = api_compat.Principal(tenant="tenant-unmanaged", subject="user-1", email=None)
    error = error_from(operator_identity.operator_session(unmanaged))
    assert error.status_code == 403
    assert error.code == "operator_tenant_not_managed"


def test_operator_rejection_of_nonadmin_user_creation(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = QueuedPool(rows=[identity_row(role="viewer")])
    install_pool(monkeypatch, pool)

    error = error_from(
        operator_identity.create_operator_identity(
            operator_identity.OperatorIdentityCreateRequest(
                provider_subject="bob",
                email="bob@agentmaxxing.example",
                display_name="Bob Operator",
            ),
            principal(),
        )
    )
    assert error.status_code == 403
    assert error.code == "operator_admin_required"


def test_operator_rejection_of_last_admin_removal(monkeypatch: pytest.MonkeyPatch) -> None:
    admin = identity_row(role="admin")
    pool = QueuedPool(rows=[admin, admin], values=[0])
    install_pool(monkeypatch, pool)

    error = error_from(
        operator_identity.remove_operator_identity(
            IDENTITY_ID,
            operator_identity.OperatorIdentityRemovalRequest(reason="Remove sole admin"),
            principal(),
        )
    )
    assert error.status_code == 409
    assert error.code == "last_operator_admin"

