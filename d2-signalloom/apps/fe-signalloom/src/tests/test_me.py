"""GET /api/v1/me: the server's answer to who the caller is.

The dashboard used to decide superadmin in the browser by matching
``demo-user@signalloom.local`` (``auth/superadmin.ts``). That is fine as a
visibility control and wrong as soon as ``API_SUPERADMIN_EMAILS`` is configured
to anything else, because the client's idea of superadmin and the server's can
then disagree. This route is the one the dashboard follows instead, so what
matters is that it reports exactly the decision ``require_superadmin`` makes.
"""
from __future__ import annotations

import pytest

import api_compat
from superadmin import is_superadmin
from tests.test_agent_discovery import bearer, client_for, token_for


class _NoDiscovery:
    def __init__(self, *_a, **_k) -> None:
        pass

    async def __aenter__(self) -> "_NoDiscovery":
        return self

    async def __aexit__(self, *_a) -> bool:
        return False

    async def get(self, *_a, **_k):
        import httpx

        return httpx.Response(200, json={"agents": []})


def test_it_reports_the_callers_verified_subject_and_tenant(monkeypatch):
    with client_for(monkeypatch, _NoDiscovery) as client:
        body = client.get("/api/v1/me", headers=bearer(token_for("alice"))).json()

    assert body["subject"] == "alice"
    assert body["tenant"] == "tenant-a"
    assert body["superadmin"] is False


def test_a_superadmin_is_reported_as_one(monkeypatch):
    with client_for(monkeypatch, _NoDiscovery) as client:
        monkeypatch.setattr(
            api_compat.settings,
            "api_subject_tenants",
            {"alice": "tenant-a", "demo-user": "tenant-demo"},
        )
        # Stated explicitly, not inherited: tests/test_eap_anonymous_surface.py
        # assigns settings.api_superadmin_emails/subjects directly rather than
        # through monkeypatch, so those defaults are gone for every module that
        # runs after it in a full session. A test that needs a superadmin has to
        # name one.
        monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {"demo-user"})
        monkeypatch.setattr(api_compat.settings, "api_superadmin_emails", set())
        body = client.get("/api/v1/me", headers=bearer(token_for("demo-user"))).json()

    assert body["subject"] == "demo-user"
    assert body["superadmin"] is True


def test_it_agrees_with_the_gate_the_server_itself_applies(monkeypatch):
    """The whole point: one decision, reported, not a second one re-derived."""
    with client_for(monkeypatch, _NoDiscovery) as client:
        monkeypatch.setattr(
            api_compat.settings,
            "api_subject_tenants",
            {"alice": "tenant-a", "demo-user": "tenant-demo"},
        )
        # The env-driven allow-list, which is the documented path. Naming a
        # subject that is not the demo user is what the browser name match
        # could never follow.
        monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {"alice"})
        monkeypatch.setattr(api_compat.settings, "api_superadmin_emails", set())

        reported = client.get("/api/v1/me", headers=bearer(token_for("alice"))).json()
        demoted = client.get("/api/v1/me", headers=bearer(token_for("demo-user"))).json()

        assert reported["superadmin"] is is_superadmin(
            api_compat.Principal(tenant="tenant-a", subject="alice", email=None)
        )
        assert reported["superadmin"] is True
        # And the formerly hard-coded demo user is no longer superadmin, which
        # the browser name match would have got wrong in both directions.
        assert demoted["superadmin"] is False

        # The gate itself follows the same configuration.
        assert client.get("/api/v1/auth/check", headers=bearer(token_for("alice"))).status_code == 204
        assert client.get("/api/v1/auth/check", headers=bearer(token_for("demo-user"))).status_code == 403


def test_an_anonymous_caller_is_refused(monkeypatch):
    with client_for(monkeypatch, _NoDiscovery) as client:
        assert client.get("/api/v1/me").status_code == 401


def test_identity_is_never_taken_from_a_header_the_client_can_author(monkeypatch):
    with client_for(monkeypatch, _NoDiscovery) as client:
        token = bearer(token_for("alice"))
        for extra in (
            {"X-Forwarded-User": "demo-user"},
            {"X-Tenant-Id": "tenant-b"},
            {"X-Principal": "demo-user"},
        ):
            body = client.get("/api/v1/me", headers={**token, **extra}).json()
            assert body == {
                "subject": "alice",
                "tenant": "tenant-a",
                "email": None,
                "superadmin": False,
            }, extra
