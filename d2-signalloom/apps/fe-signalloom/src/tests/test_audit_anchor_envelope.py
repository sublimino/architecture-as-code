"""DSSE signing, independent verification, and local evidence storage."""
import base64
import json

import pytest

from audit_anchor.anchor import (
    AnchorError,
    FileAnchorStore,
    build_statement,
    checkpoint_from_envelope,
    key_id,
    load_private_key,
    load_public_key,
    pae,
    require_rekor_if_configured,
    sign_envelope,
    store_from_env,
    verify_envelope,
)
from audit_anchor.checkpoint import GENESIS_DIGEST, PREDICATE_TYPE, build_checkpoint


@pytest.fixture
def keypair():
    from cryptography.hazmat.primitives.asymmetric import ed25519

    private = ed25519.Ed25519PrivateKey.generate()
    return private, private.public_key()


def _checkpoint(index=0, actor="demo-actor"):
    row = {
        "id": "00000000-0000-0000-0000-000000000001",
        "tenant_id": "tenant-demo",
        "ts": "2026-08-13T22:00:01.000000Z",
        "event_type": "agent.stunned",
        "agent_id": None,
        "agent_name": "Cardvault Agent",
        "actor": actor,
        "detail": '{"outcome": "stunned"}',
    }
    return build_checkpoint(
        [row],
        index=index,
        prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None,
        window_end_inclusive="2026-08-13T22:01:00.000000Z",
        cumulative_row_count_before=0,
        tenant_scope="*",
        boundary_basis="xact_clamp",
    )


def test_pae_matches_the_dsse_specification():
    assert pae("http://example.com/T", b"hello") == b"DSSEv1 20 http://example.com/T 5 hello"


def test_pae_length_is_over_bytes_not_characters():
    assert pae("é", b"") == b"DSSEv1 2 \xc3\xa9 0 "


def test_pae_is_unambiguous_across_a_moved_boundary():
    assert pae("ab", b"cd") != pae("abc", b"d")


def test_envelope_round_trips(keypair):
    private, public = keypair
    checkpoint = _checkpoint()
    envelope = sign_envelope(build_statement(checkpoint), private)
    assert checkpoint_from_envelope(envelope, public) == checkpoint


def test_envelope_declares_the_in_toto_payload_type(keypair):
    private, _ = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    assert envelope["payloadType"] == "application/vnd.in-toto+json"
    assert json.loads(base64.b64decode(envelope["payload"]))["predicateType"] == PREDICATE_TYPE


def test_keyid_is_derived_from_the_public_key(keypair):
    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    assert envelope["signatures"][0]["keyid"] == key_id(public)


def test_a_tampered_payload_fails_verification(keypair):
    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    statement = json.loads(base64.b64decode(envelope["payload"]))
    statement["predicate"]["row_count"] = 0
    envelope["payload"] = base64.b64encode(
        json.dumps(statement, sort_keys=True, separators=(",", ":")).encode()
    ).decode()
    with pytest.raises(AnchorError):
        verify_envelope(envelope, public)


def test_a_signature_from_another_key_is_rejected(keypair):
    from cryptography.hazmat.primitives.asymmetric import ed25519

    private, _ = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    with pytest.raises(AnchorError):
        verify_envelope(envelope, ed25519.Ed25519PrivateKey.generate().public_key())


def test_a_predicate_that_disagrees_with_its_signed_subject_is_rejected(keypair):
    private, public = keypair
    statement = build_statement(_checkpoint())
    statement["predicate"]["row_count"] = 99
    with pytest.raises(AnchorError, match="subject"):
        checkpoint_from_envelope(sign_envelope(statement, private), public)


def test_payload_type_is_covered_by_the_signature(keypair):
    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    envelope["payloadType"] = "application/json"
    with pytest.raises(AnchorError):
        verify_envelope(envelope, public)


def test_expected_key_id_rejects_keyid_replacement(keypair):
    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    envelope["signatures"][0]["keyid"] = "00" * 32
    with pytest.raises(AnchorError):
        verify_envelope(envelope, public)


def test_file_store_writes_and_reads_signed_evidence(tmp_path, keypair):
    private, public = keypair
    store = FileAnchorStore(tmp_path / "anchors")
    checkpoints = [_checkpoint(index=i) for i in range(3)]
    references = [
        store.publish(cp, sign_envelope(build_statement(cp), private))
        for cp in checkpoints
    ]
    assert all((tmp_path / "anchors") in __import__("pathlib").Path(ref).parents for ref in references)
    recovered = [checkpoint_from_envelope(e, public) for e in store.fetch_all()]
    assert [cp.index for cp in recovered] == [0, 1, 2]


def test_file_store_refuses_to_overwrite_evidence(tmp_path, keypair):
    private, _ = keypair
    store = FileAnchorStore(tmp_path / "anchors")
    checkpoint = _checkpoint()
    envelope = sign_envelope(build_statement(checkpoint), private)
    store.publish(checkpoint, envelope)
    with pytest.raises(AnchorError, match="refusing to overwrite"):
        store.publish(checkpoint, envelope)


def test_file_store_reports_malformed_evidence(tmp_path):
    directory = tmp_path / "anchors"
    directory.mkdir()
    (directory / "00000000-broken.dsse.json").write_text("not-json")
    with pytest.raises(json.JSONDecodeError):
        FileAnchorStore(directory).fetch_all()


def test_file_store_on_a_missing_directory_is_empty(tmp_path):
    assert FileAnchorStore(tmp_path / "missing").fetch_all() == []


def test_store_from_env_returns_explicit_file_store(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIT_ANCHOR_DIR", str(tmp_path))
    monkeypatch.delenv("ARCHIVISTA_URL", raising=False)
    monkeypatch.delenv("AUDIT_ANCHOR_REQUIRE_LOG", raising=False)
    store, label = store_from_env()
    assert isinstance(store, FileAnchorStore)
    assert store.directory == tmp_path
    assert label == f"file:{tmp_path}"


@pytest.mark.parametrize("name", ["ARCHIVISTA_URL", "AUDIT_ANCHOR_REQUIRE_LOG"])
def test_store_from_env_rejects_stale_archivista_configuration(monkeypatch, name):
    monkeypatch.delenv("ARCHIVISTA_URL", raising=False)
    monkeypatch.delenv("AUDIT_ANCHOR_REQUIRE_LOG", raising=False)
    monkeypatch.setenv(name, "stale")
    with pytest.raises(AnchorError, match=f"support was removed.*{name}"):
        store_from_env()


def _write_keypair(directory):
    from cryptography.hazmat.primitives.asymmetric import ed25519
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
        PublicFormat,
    )

    directory.mkdir(parents=True, exist_ok=True)
    private = ed25519.Ed25519PrivateKey.generate()
    (directory / "witness.pem").write_bytes(
        private.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    )
    (directory / "witness-pub.pem").write_bytes(
        private.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)
    )
    return directory


def test_keys_load_from_an_absolute_path_outside_the_repository(tmp_path):
    keys = _write_keypair(tmp_path / "elsewhere" / ".keys")
    private = load_private_key(str(keys / "witness.pem"))
    public = load_public_key(str(keys / "witness-pub.pem"))
    checkpoint = _checkpoint()
    assert checkpoint_from_envelope(sign_envelope(build_statement(checkpoint), private), public) == checkpoint


def test_an_absolute_key_path_is_not_reinterpreted_relative_to_the_cwd(tmp_path, monkeypatch):
    keys = _write_keypair(tmp_path / "elsewhere" / ".keys")
    elsewhere = tmp_path / "some" / "other" / "cwd"
    elsewhere.mkdir(parents=True)
    monkeypatch.chdir(elsewhere)
    assert load_private_key(str(keys / "witness.pem")) is not None


def test_a_missing_key_names_the_resolved_absolute_path(tmp_path):
    missing = tmp_path / "absent" / "witness.pem"
    with pytest.raises(AnchorError) as excinfo:
        load_private_key(str(missing))
    assert str(missing) in str(excinfo.value)
    assert "make signing-keys" in str(excinfo.value)


def test_a_missing_key_does_not_raise_a_bare_oserror(tmp_path):
    with pytest.raises(AnchorError):
        load_public_key(str(tmp_path / "missing.pem"))


def test_configured_rekor_failure_is_explicit(monkeypatch):
    monkeypatch.setenv("REKOR_URL", "http://127.0.0.1:1")
    with pytest.raises(AnchorError, match="Rekor.*unavailable"):
        require_rekor_if_configured(timeout=1)


def test_reachable_rekor_is_not_mistaken_for_publication(monkeypatch):
    from contextlib import nullcontext
    from types import SimpleNamespace

    monkeypatch.setenv("REKOR_URL", "http://rekor.example.invalid")
    monkeypatch.setattr(
        "urllib.request.urlopen", lambda *args, **kwargs: nullcontext(SimpleNamespace(status=200))
    )
    with pytest.raises(AnchorError, match="no checkpoint was published"):
        require_rekor_if_configured()
