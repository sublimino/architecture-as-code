"""The gateway credential fe-signalloom presents to signal-ingest.

signal-ingest authenticates every route. fe-signalloom serves every tenant's dashboard users
through one static key (``fe-signalloom-gateway``) holding ``tenant:act-for``: each request names
the verified user's tenant in ``X-SignalLoom-Acting-Tenant`` and signal-ingest scopes it there.
A superadmin reads across tenants as ``*``; nobody else can ever produce ``*``. The key is read
from its mounted Secret file and is never sent missing, never logged.
"""
from __future__ import annotations

import logging

import pytest

import ingest_client
from api_compat import APIError, Principal

GATEWAY_KEY = "gWk7x2Lq9pN4cR8tY1kD6hF3jS5aZ0mE7uB2oG9iX4w"


@pytest.fixture()
def key_file(tmp_path, monkeypatch):
    path = tmp_path / "token"
    path.write_text(GATEWAY_KEY + "\n")
    monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(path))
    return path


@pytest.fixture()
def superadmins(monkeypatch):
    import superadmin

    monkeypatch.setattr(superadmin.settings, "api_superadmin_emails", ["root@signalloom.local"], raising=False)
    monkeypatch.setattr(superadmin.settings, "api_superadmin_subjects", ["root"], raising=False)


USER = Principal(tenant="kusari", subject="alice", email="alice@kusari.example")
ADMIN = Principal(tenant="tenant-demo", subject="root", email="root@signalloom.local")


def test_headers_carry_the_gateway_key_and_the_users_tenant(key_file, superadmins):
    headers = ingest_client.ingest_headers(USER)
    assert headers == {
        "Authorization": f"Bearer {GATEWAY_KEY}",
        "X-SignalLoom-Acting-Tenant": "kusari",
        "X-SignalLoom-Acting-Subject": "alice",
    }


def test_a_superadmin_reads_as_all_tenants_but_writes_as_its_own(key_file, superadmins):
    assert ingest_client.ingest_headers(ADMIN)["X-SignalLoom-Acting-Tenant"] == "*"
    assert ingest_client.ingest_headers(ADMIN, write=True)["X-SignalLoom-Acting-Tenant"] == "tenant-demo"


@pytest.mark.parametrize("tenant", ["*", " *", "*\n", "", "kusari,tenant-b"])
def test_a_non_superadmin_can_never_produce_all_tenants(key_file, superadmins, tenant):
    # A tenant mapping that happens to be "*" (or blank, or a list) must not become a wildcard.
    principal = Principal(tenant=tenant, subject="mallory", email="mallory@kusari.example")
    with pytest.raises(APIError) as err:
        ingest_client.ingest_headers(principal)
    assert err.value.status_code == 403
    assert err.value.code == "tenant_forbidden"


@pytest.mark.parametrize("content", [None, "", "\n", "short"])
def test_a_missing_or_unusable_key_is_a_503_never_an_anonymous_request(tmp_path, monkeypatch, superadmins, content):
    path = tmp_path / "token"
    if content is not None:
        path.write_text(content)
    monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(path))
    with pytest.raises(APIError) as err:
        ingest_client.ingest_headers(USER)
    assert err.value.status_code == 503
    assert err.value.code == "ingest_credential_unavailable"


def test_the_key_is_reread_so_a_rotation_needs_no_restart(key_file, superadmins):
    ingest_client.ingest_headers(USER)
    rotated = "Rt" + GATEWAY_KEY[2:]
    key_file.write_text(rotated)
    assert ingest_client.ingest_headers(USER)["Authorization"] == f"Bearer {rotated}"


def test_the_key_is_never_logged(key_file, superadmins, caplog, tmp_path, monkeypatch):
    caplog.set_level(logging.DEBUG)
    ingest_client.ingest_headers(USER)
    monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(tmp_path / "absent"))
    with pytest.raises(APIError):
        ingest_client.ingest_headers(USER)
    assert GATEWAY_KEY not in caplog.text
