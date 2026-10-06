"""A superadmin's cross-tenant read writes one audit event naming the tenant(s) it saw.

Andy's decision (2026-10-06): superadmin keeps its cross-tenant view for the pilot, but every
read whose response discloses another tenant's data must write an audit event -- through the
same durable path every other recorded decision uses (api_compat._audit_outbound_request) -- and
an audit write failure must fail the request closed, matching the existing audit-decision
convention (test_router_audit_fail_closed.py, test_audit_pool_fail_closed.py).

Exercised two ways:

1. Directly against ``cross_tenant_audit`` -- the extraction and the decision of whether to
   write anything at all, with no FastAPI or network involved.
2. Through ``GET /api/signals/observations``, the first wired-up route, with signal-ingest
   mocked via ``httpx.MockTransport`` (the pattern test_signal_fusion.py already uses) so the
   proxy's own fail-closed wiring is what is under test, not a hand-rolled substitute for it.
"""
from __future__ import annotations

import asyncio
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

import api_compat
import cross_tenant_audit
from api_compat import APIError, Principal, authenticated_principal, settings
from main import app

SUPERADMIN_TENANT = "tenant-cta-superadmin"
OTHER_TENANT = "tenant-cta-other"
SUPERADMIN = Principal(tenant=SUPERADMIN_TENANT, subject="cta-root", email="cta-root@signalloom.local")
PLAIN_USER = Principal(tenant=SUPERADMIN_TENANT, subject="cta-alice", email="cta-alice@signalloom.local")


@pytest.fixture(autouse=True)
def superadmins(monkeypatch: pytest.MonkeyPatch) -> None:
    import superadmin

    monkeypatch.setattr(superadmin.settings, "api_superadmin_emails", [SUPERADMIN.email], raising=False)
    monkeypatch.setattr(superadmin.settings, "api_superadmin_subjects", [SUPERADMIN.subject], raising=False)


@pytest.fixture(autouse=True)
def _clean_tenant_state() -> Any:
    api_compat.reset_tenant_state(SUPERADMIN_TENANT)
    yield
    api_compat.reset_tenant_state(SUPERADMIN_TENANT)


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


def _memory_events(tenant: str) -> list[dict[str, Any]]:
    with api_compat._STORE_LOCK:
        return list(api_compat._AUDIT_EVENTS.get(tenant, []))


# ---------------------------------------------------------------------------
# 1. Unit-level: cross_tenant_audit.audit_cross_tenant_read
# ---------------------------------------------------------------------------


class TestExtraction:
    def test_finds_tenant_id_nested_under_labels(self) -> None:
        """signal-ingest nests the tenant label inside Labels on an observation."""
        content = [
            {"id": "obs-1", "labels": {"tenant_id": SUPERADMIN_TENANT}},
            {"id": "obs-2", "labels": {"tenant_id": OTHER_TENANT}},
        ]
        assert cross_tenant_audit.tenant_ids_in_response(content) == {SUPERADMIN_TENANT, OTHER_TENANT}

    def test_finds_top_level_tenant_id(self) -> None:
        """Policy findings/decisions carry tenant_id at the top level of each row."""
        content = [{"id": "f-1", "tenant_id": OTHER_TENANT}]
        assert cross_tenant_audit.tenant_ids_in_response(content) == {OTHER_TENANT}

    def test_finds_tenant_field_fe_signalloom_convention(self) -> None:
        """invites.InviteSummary uses `tenant`, not `tenant_id`."""
        content = {"invites": [{"id": "i-1", "tenant": OTHER_TENANT}]}
        assert cross_tenant_audit.tenant_ids_in_response(content) == {OTHER_TENANT}

    def test_empty_or_scalar_content_finds_nothing(self) -> None:
        assert cross_tenant_audit.tenant_ids_in_response([]) == set()
        assert cross_tenant_audit.tenant_ids_in_response({}) == set()
        assert cross_tenant_audit.tenant_ids_in_response(None) == set()
        assert cross_tenant_audit.tenant_ids_in_response("just a string") == set()


class TestAuditDecision:
    """audit_cross_tenant_read decides whether to write anything at all.

    Driven with ``asyncio.run`` from plain ``def`` tests, matching
    test_audit_pool_fail_closed.py and test_router_audit_fail_closed.py: this
    suite's pytest.ini configures neither pytest-asyncio's ``asyncio_mode``
    nor an anyio backend, so a bare ``async def test_...`` would not actually
    run under the plugins ``make test-all-offline``/``test-sldc-offline``
    install.
    """

    @staticmethod
    def _run(principal: Principal, content: Any) -> None:
        asyncio.run(
            cross_tenant_audit.audit_cross_tenant_read(
                principal, "GET /api/v1/observations", content, what="Reading observations cross-tenant",
            )
        )

    def test_cross_tenant_read_emits_exactly_one_event_naming_both_tenants(self) -> None:
        content = [
            {"id": "obs-1", "tenant_id": SUPERADMIN_TENANT},
            {"id": "obs-2", "tenant_id": OTHER_TENANT},
        ]
        self._run(SUPERADMIN, content)
        events = _memory_events(SUPERADMIN_TENANT)
        assert len(events) == 1, events
        event = events[0]
        assert event["event_type"] == "audit.cross_tenant_read"
        assert event["actor"] == SUPERADMIN.actor
        assert event["detail"]["action"] == "cross_tenant_read"
        assert event["detail"]["route"] == "GET /api/v1/observations"
        assert event["detail"]["tenant_ids"] == sorted({SUPERADMIN_TENANT, OTHER_TENANT})
        assert event["detail"]["result_count"] == 2
        assert "timestamp" in event

    def test_same_tenant_read_by_superadmin_emits_nothing(self) -> None:
        """Only the superadmin's own tenant appears -- nothing cross-tenant actually happened."""
        content = [{"id": "obs-1", "tenant_id": SUPERADMIN_TENANT}]
        self._run(SUPERADMIN, content)
        assert _memory_events(SUPERADMIN_TENANT) == []

    def test_non_superadmin_read_emits_nothing_even_with_other_tenant_data(self) -> None:
        """Guards the gate itself: a non-superadmin's read is never audited by this path,
        whatever the (hypothetical) response contains."""
        content = [{"id": "obs-1", "tenant_id": OTHER_TENANT}]
        self._run(PLAIN_USER, content)
        assert _memory_events(SUPERADMIN_TENANT) == []

    def test_empty_response_emits_nothing(self) -> None:
        self._run(SUPERADMIN, [])
        assert _memory_events(SUPERADMIN_TENANT) == []


class TestFailClosed:
    """An audit write failure refuses the read, matching the audit-decision convention."""

    DSN = "postgresql://unused:unused@127.0.0.1:1/unused"

    def test_audit_failure_raises_503_database_unavailable(
        self, monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        async def unreachable() -> None:
            return None

        monkeypatch.setattr(settings, "database_url", self.DSN)
        monkeypatch.setattr(api_compat, "_get_pool", unreachable)

        content = [
            {"id": "obs-1", "tenant_id": SUPERADMIN_TENANT},
            {"id": "obs-2", "tenant_id": OTHER_TENANT},
        ]
        with pytest.raises(APIError) as err:
            asyncio.run(
                cross_tenant_audit.audit_cross_tenant_read(
                    SUPERADMIN, "GET /api/v1/observations", content, what="Reading observations cross-tenant",
                )
            )
        assert err.value.status_code == 503
        assert err.value.code == "database_unavailable"
        # Nothing was recorded either -- a failed write leaves no partial trace.
        assert _memory_events(SUPERADMIN_TENANT) == []


# ---------------------------------------------------------------------------
# 2. Through the wire: GET /api/signals/observations
# ---------------------------------------------------------------------------


class TestObservationsRouteIntegration:
    @pytest.fixture()
    def ingest(self, monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
        state: dict[str, Any] = {"body": []}

        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, json=state["body"])

        real = httpx.AsyncClient

        class Stub(real):  # type: ignore[misc, valid-type]
            def __init__(self, *args: Any, **kwargs: Any) -> None:
                kwargs["transport"] = httpx.MockTransport(handler)
                super().__init__(*args, **kwargs)

        monkeypatch.setattr(httpx, "AsyncClient", Stub)
        return state

    def test_superadmin_cross_tenant_response_emits_one_event(
        self, client: TestClient, ingest: dict[str, Any],
    ) -> None:
        ingest["body"] = [
            {"id": "obs-1", "labels": {"tenant_id": SUPERADMIN_TENANT}},
            {"id": "obs-2", "labels": {"tenant_id": OTHER_TENANT}},
        ]
        app.dependency_overrides[authenticated_principal] = lambda: SUPERADMIN
        try:
            resp = client.get("/api/signals/observations")
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)
        assert resp.status_code == 200, resp.text
        events = _memory_events(SUPERADMIN_TENANT)
        assert len(events) == 1, events
        assert events[0]["event_type"] == "audit.cross_tenant_read"
        assert events[0]["detail"]["tenant_ids"] == sorted({SUPERADMIN_TENANT, OTHER_TENANT})

    def test_superadmin_same_tenant_response_emits_nothing(
        self, client: TestClient, ingest: dict[str, Any],
    ) -> None:
        ingest["body"] = [{"id": "obs-1", "labels": {"tenant_id": SUPERADMIN_TENANT}}]
        app.dependency_overrides[authenticated_principal] = lambda: SUPERADMIN
        try:
            resp = client.get("/api/signals/observations")
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)
        assert resp.status_code == 200, resp.text
        assert _memory_events(SUPERADMIN_TENANT) == []

    def test_non_superadmin_emits_nothing(
        self, client: TestClient, ingest: dict[str, Any],
    ) -> None:
        # A plain user's own request never acts for "*", so signal-ingest would not actually
        # return another tenant's rows -- but even if it somehow did, the gate below is on
        # is_superadmin, not on what came back.
        ingest["body"] = [{"id": "obs-1", "labels": {"tenant_id": OTHER_TENANT}}]
        app.dependency_overrides[authenticated_principal] = lambda: PLAIN_USER
        try:
            resp = client.get("/api/signals/observations")
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)
        assert resp.status_code == 200, resp.text
        assert _memory_events(SUPERADMIN_TENANT) == []

    def test_audit_failure_fails_the_request_closed(
        self, client: TestClient, ingest: dict[str, Any], monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        ingest["body"] = [
            {"id": "obs-1", "labels": {"tenant_id": SUPERADMIN_TENANT}},
            {"id": "obs-2", "labels": {"tenant_id": OTHER_TENANT}},
        ]

        async def unreachable() -> None:
            return None

        monkeypatch.setattr(settings, "database_url", TestFailClosed.DSN)
        monkeypatch.setattr(api_compat, "_get_pool", unreachable)

        app.dependency_overrides[authenticated_principal] = lambda: SUPERADMIN
        try:
            resp = client.get("/api/signals/observations")
        finally:
            app.dependency_overrides.pop(authenticated_principal, None)
        assert resp.status_code == 503, resp.text
        assert resp.json()["error"]["code"] == "database_unavailable"
        assert _memory_events(SUPERADMIN_TENANT) == []
