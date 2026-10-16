"""connector_credentials: AES-256-GCM sealing bound to (tenant, connector)."""
from __future__ import annotations

import secrets

import pytest

import connector_credentials as cc


@pytest.fixture
def key(tmp_path, monkeypatch):
    path = tmp_path / "key"
    path.write_text(secrets.token_hex(32))
    monkeypatch.setenv(cc.KEY_FILE_ENV, str(path))
    return path


def test_round_trip(key):
    sealed = cc.seal_credentials("t1", "conn-claude-01", {"api_key": "k", "workspace_id": "w"})
    assert sealed.startswith("vault:v1:")
    assert cc.open_credentials("t1", "conn-claude-01", sealed) == {"api_key": "k", "workspace_id": "w"}


def test_each_seal_uses_a_fresh_nonce(key):
    assert cc.seal_credentials("t1", "c", {"a": "b"}) != cc.seal_credentials("t1", "c", {"a": "b"})


@pytest.mark.parametrize("tenant, connector", [("t2", "conn-claude-01"), ("t1", "conn-claude-02")])
def test_ciphertext_cannot_be_moved_to_another_tenant_or_connector(key, tenant, connector):
    sealed = cc.seal_credentials("t1", "conn-claude-01", {"api_key": "k"})
    with pytest.raises(cc.CredentialDecryptError):
        cc.open_credentials(tenant, connector, sealed)


def test_a_different_key_cannot_open_it(key, tmp_path, monkeypatch):
    sealed = cc.seal_credentials("t1", "c", {"api_key": "k"})
    other = tmp_path / "other"
    other.write_text(secrets.token_hex(32))
    monkeypatch.setenv(cc.KEY_FILE_ENV, str(other))
    with pytest.raises(cc.CredentialDecryptError):
        cc.open_credentials("t1", "c", sealed)


@pytest.mark.parametrize("content", [None, "", "deadbeef", "zz" * 32, "00" * 31])
def test_no_usable_key_is_unavailable_never_a_fallback(tmp_path, monkeypatch, content):
    if content is None:
        monkeypatch.delenv(cc.KEY_FILE_ENV, raising=False)
    else:
        path = tmp_path / "key"
        path.write_text(content)
        monkeypatch.setenv(cc.KEY_FILE_ENV, str(path))
    with pytest.raises(cc.CredentialStoreUnavailable):
        cc.seal_credentials("t1", "c", {"api_key": "k"})


def test_a_named_key_file_that_does_not_exist_is_unavailable(tmp_path, monkeypatch):
    monkeypatch.setenv(cc.KEY_FILE_ENV, str(tmp_path / "absent"))
    with pytest.raises(cc.CredentialStoreUnavailable):
        cc.seal_credentials("t1", "c", {"api_key": "k"})


def test_the_error_never_carries_the_key_or_the_plaintext(tmp_path, monkeypatch):
    path = tmp_path / "key"
    path.write_text("not-hex-secretish")
    monkeypatch.setenv(cc.KEY_FILE_ENV, str(path))
    with pytest.raises(cc.CredentialStoreUnavailable) as exc:
        cc.seal_credentials("t1", "c", {"api_key": "PLAINTEXT"})
    assert "not-hex-secretish" not in str(exc.value) and "PLAINTEXT" not in str(exc.value)
