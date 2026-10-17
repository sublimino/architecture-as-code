"""SA-TODO-003: connector credentials live in OpenBao KV v2, never in Postgres.

These tests drive ``connector_secret_store.OpenBaoKvStore`` against a mocked
OpenBao HTTP API (respx). The token is re-read from BAO_TOKEN_FILE on every
request, as the bao agent sidecar rotates it. Every failure is
CredentialStoreUnavailable (the router answers 503); nothing falls back.
"""
from __future__ import annotations

import json

import httpx
import pytest
import respx

import connector_secret_store as css

ADDR = "http://openbao.test:8200"
PATH = "signalloom/tenants/a1b2c3d4/connectors/conn-claude-01"


@pytest.fixture
def token_file(tmp_path):
    path = tmp_path / "token"
    path.write_text("s.first\n")
    return path


@pytest.fixture
def store(token_file):
    return css.OpenBaoKvStore(addr=ADDR, token_file=str(token_file))


def test_tenant_path_names_tenant_and_connector():
    assert css.tenant_path("a1b2c3d4", "conn-claude-01") == PATH


@pytest.mark.parametrize("tenant, connector", [
    ("a1b2c3d4/../x", "conn"), ("a1b2c3d4", "conn/../../other"), ("", "conn"), ("a1b2c3d4", ""),
    ("tenant b", "conn"), ("a1b2c3d4", "conn%2f"), ("..", "conn"),
])
def test_ids_that_could_leave_the_tenant_path_are_refused(tenant, connector):
    with pytest.raises(css.CredentialStoreUnavailable):
        css.tenant_path(tenant, connector)


def test_put_writes_kv_v2_with_the_file_token_and_returns_path_and_version(store):
    with respx.mock(assert_all_called=True) as mock:
        route = mock.post(f"{ADDR}/v1/kv/data/{PATH}").mock(
            return_value=httpx.Response(200, json={"data": {"version": 3}}))
        assert store.put("a1b2c3d4", "conn-claude-01", {"api_key": "k"}) == (PATH, 3)
    request = route.calls.last.request
    assert request.headers["X-Vault-Token"] == "s.first"
    assert json.loads(request.read()) == {"data": {"api_key": "k"}}


def test_the_token_file_is_read_again_on_every_request(store, token_file):
    with respx.mock() as mock:
        route = mock.get(f"{ADDR}/v1/kv/data/{PATH}").mock(
            return_value=httpx.Response(200, json={"data": {"data": {"api_key": "k"}}}))
        store.get("a1b2c3d4", "conn-claude-01", PATH, 1)
        token_file.write_text("s.rotated\n")
        store.get("a1b2c3d4", "conn-claude-01", PATH, 1)
    assert [c.request.headers["X-Vault-Token"] for c in route.calls] == ["s.first", "s.rotated"]


def test_get_reads_the_recorded_version(store):
    with respx.mock() as mock:
        route = mock.get(f"{ADDR}/v1/kv/data/{PATH}", params={"version": "2"}).mock(
            return_value=httpx.Response(200, json={"data": {"data": {"api_key": "v2"}}}))
        assert store.get("a1b2c3d4", "conn-claude-01", PATH, 2) == {"api_key": "v2"}
    assert route.called


def test_get_refuses_a_reference_to_another_tenants_path(store):
    other = "signalloom/tenants/ffffffff/connectors/conn-claude-01"
    with respx.mock(assert_all_called=False) as mock:
        route = mock.get(url__startswith=f"{ADDR}/v1/").mock(return_value=httpx.Response(200, json={}))
        with pytest.raises(css.CredentialStoreUnavailable, match="does not belong"):
            store.get("a1b2c3d4", "conn-claude-01", other, 1)
    assert not route.called


def test_get_refuses_a_reference_to_another_connector(store):
    with pytest.raises(css.CredentialStoreUnavailable, match="does not belong"):
        store.get("a1b2c3d4", "conn-claude-01", "signalloom/tenants/a1b2c3d4/connectors/conn-github-01", 1)


def test_delete_removes_every_version_through_metadata(store):
    with respx.mock(assert_all_called=True) as mock:
        route = mock.delete(f"{ADDR}/v1/kv/metadata/{PATH}").mock(return_value=httpx.Response(204))
        store.delete("a1b2c3d4", "conn-claude-01")
    assert route.called


def test_delete_of_an_absent_secret_is_not_an_error(store):
    with respx.mock() as mock:
        mock.delete(f"{ADDR}/v1/kv/metadata/{PATH}").mock(return_value=httpx.Response(404))
        store.delete("a1b2c3d4", "conn-claude-01")


@pytest.mark.parametrize("response", [
    httpx.ConnectError("refused"), httpx.ReadTimeout("slow"),
    httpx.Response(403, json={"errors": ["permission denied"]}),
    httpx.Response(500, json={"errors": ["sealed"]}), httpx.Response(503),
])
@pytest.mark.parametrize("op", ["put", "get", "delete"])
def test_any_openbao_failure_is_credential_store_unavailable(store, response, op):
    with respx.mock() as mock:
        route = mock.route(url__startswith=f"{ADDR}/v1/kv/")
        if isinstance(response, Exception):
            route.mock(side_effect=response)
        else:
            route.mock(return_value=response)
        with pytest.raises(css.CredentialStoreUnavailable):
            if op == "put":
                store.put("a1b2c3d4", "conn-claude-01", {"api_key": "k"})
            elif op == "get":
                store.get("a1b2c3d4", "conn-claude-01", PATH, 1)
            else:
                store.delete("a1b2c3d4", "conn-claude-01")


def test_a_missing_secret_is_unavailable_not_empty(store):
    with respx.mock() as mock:
        mock.get(f"{ADDR}/v1/kv/data/{PATH}").mock(return_value=httpx.Response(404))
        with pytest.raises(css.CredentialStoreUnavailable, match="no secret"):
            store.get("a1b2c3d4", "conn-claude-01", PATH, 1)


def test_unconfigured_store_is_unavailable(monkeypatch, tmp_path):
    monkeypatch.delenv("BAO_ADDR", raising=False)
    monkeypatch.delenv("BAO_TOKEN_FILE", raising=False)
    with pytest.raises(css.CredentialStoreUnavailable):
        css.OpenBaoKvStore().require()
    with pytest.raises(css.CredentialStoreUnavailable):
        css.OpenBaoKvStore(addr=ADDR, token_file=str(tmp_path / "absent")).require()


def test_errors_never_carry_the_secret_or_the_token(store):
    with respx.mock() as mock:
        mock.post(f"{ADDR}/v1/kv/data/{PATH}").mock(return_value=httpx.Response(500, text="boom s.first sk-ant-x"))
        with pytest.raises(css.CredentialStoreUnavailable) as err:
            store.put("a1b2c3d4", "conn-claude-01", {"api_key": "sk-ant-x"})
    assert "s.first" not in str(err.value) and "sk-ant-x" not in str(err.value)


# --- open_row: the one reader the router and remote agent sync share ------

class _Row(dict):
    pass


def test_open_row_reads_the_reference_from_the_store():
    from tests.connector_secret_store_fake import FakeKvStore
    kv = FakeKvStore()
    ref, version = kv.put("a1b2c3d4", "conn-claude-01", {"api_key": "k"})
    row = _Row(connector_id="conn-claude-01", credentials_ref=ref, credentials_version=version,
               credentials_ciphertext=None)
    assert css.open_row("a1b2c3d4", row, store=kv) == {"api_key": "k"}


def test_open_row_without_credentials_is_empty():
    from tests.connector_secret_store_fake import FakeKvStore
    row = _Row(connector_id="conn-claude-01", credentials_ref=None, credentials_version=None,
               credentials_ciphertext=None)
    assert css.open_row("a1b2c3d4", row, store=FakeKvStore()) == {}


def test_open_row_never_falls_back_to_the_old_sealed_column():
    from tests.connector_secret_store_fake import FakeKvStore
    row = _Row(connector_id="conn-claude-01", credentials_ref=None, credentials_version=None,
               credentials_ciphertext="vault:v1:AAAA")
    with pytest.raises(css.CredentialStoreUnavailable, match="not migrated"):
        css.open_row("a1b2c3d4", row, store=FakeKvStore())


def test_store_seam_defaults_to_openbao_and_can_be_replaced(monkeypatch):
    from tests.connector_secret_store_fake import FakeKvStore
    fake = FakeKvStore()
    css.set_store_for_testing(fake)
    try:
        assert css.get_store() is fake
    finally:
        css.set_store_for_testing(None)
    assert isinstance(css.get_store(), css.OpenBaoKvStore)
