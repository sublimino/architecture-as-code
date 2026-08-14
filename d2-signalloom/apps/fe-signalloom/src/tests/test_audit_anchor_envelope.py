"""DSSE envelopes, signature verification, and the two anchor transports.

The Archivista tests run against a stub HTTP server implementing the documented
endpoints.  That proves our client's wire behaviour -- URLs, payload shape,
response parsing, error handling -- and it does NOT prove the real Archivista
agrees with our reading of its API.  The backend slice holding Archivista is not
deployed in the cluster this was built against, so that remains unverified and
is called out as such in the README rather than quietly assumed.
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from audit_anchor.anchor import (
    AnchorError,
    ArchivistaAnchorStore,
    FileAnchorStore,
    build_statement,
    checkpoint_from_envelope,
    key_id,
    pae,
    sign_envelope,
    verify_envelope,
)
from audit_anchor.checkpoint import GENESIS_DIGEST, PREDICATE_TYPE, build_checkpoint


@pytest.fixture
def keypair():
    from cryptography.hazmat.primitives.asymmetric import ed25519

    # ed25519 to match .keys/witness.pem, which `make signing-keys` generates
    # with `openssl genpkey -algorithm ed25519` and which scripts/attested-test.sh
    # already uses to sign attestations into Archivista.
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


# ══════════════════════════════════════════════════════════════════════════════
# PAE
# ══════════════════════════════════════════════════════════════════════════════


def test_pae_matches_the_dsse_specification():
    # The lengths are byte counts of the type and the payload respectively:
    # len("http://example.com/T") == 20, len(b"hello") == 5.
    assert pae("http://example.com/T", b"hello") == b"DSSEv1 20 http://example.com/T 5 hello"


def test_pae_length_is_over_bytes_not_characters():
    # A multi-byte type name must not desynchronise the framing.
    assert pae("é", b"") == b"DSSEv1 2 \xc3\xa9 0 "


def test_pae_is_unambiguous_across_a_moved_boundary():
    """The property PAE exists for: no choice of content shifts the parse."""
    assert pae("ab", b"cd") != pae("abc", b"d")


# ══════════════════════════════════════════════════════════════════════════════
# Signing and verification
# ══════════════════════════════════════════════════════════════════════════════


def test_envelope_round_trips(keypair):
    private, public = keypair
    checkpoint = _checkpoint()
    envelope = sign_envelope(build_statement(checkpoint), private)
    assert checkpoint_from_envelope(envelope, public) == checkpoint


def test_envelope_declares_the_in_toto_payload_type(keypair):
    private, _ = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    assert envelope["payloadType"] == "application/vnd.in-toto+json"
    assert json.loads(__import__("base64").b64decode(envelope["payload"]))[
        "predicateType"
    ] == PREDICATE_TYPE


def test_keyid_is_derived_from_the_public_key(keypair):
    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    assert envelope["signatures"][0]["keyid"] == key_id(public)


def test_a_tampered_payload_fails_verification(keypair):
    """The whole point. Rewriting the anchor requires the signing key."""
    import base64

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
    """A signer holding the key could still emit an internally inconsistent
    anchor. The chain's back-links point at the subject digest, so a predicate
    that does not re-derive to its own subject would silently break the chain."""
    import base64

    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    statement = json.loads(base64.b64decode(envelope["payload"]))
    statement["predicate"]["row_count"] = 99
    # Re-sign so the SIGNATURE is valid but the subject no longer matches.
    envelope = sign_envelope(statement, private)
    with pytest.raises(AnchorError, match="subject"):
        checkpoint_from_envelope(envelope, public)


def test_payload_type_is_covered_by_the_signature(keypair):
    private, public = keypair
    envelope = sign_envelope(build_statement(_checkpoint()), private)
    envelope["payloadType"] = "application/json"
    with pytest.raises(AnchorError):
        verify_envelope(envelope, public)


# ══════════════════════════════════════════════════════════════════════════════
# File transport
# ══════════════════════════════════════════════════════════════════════════════


def test_file_store_round_trips(tmp_path, keypair):
    private, public = keypair
    store = FileAnchorStore(tmp_path / "anchors")
    checkpoints = [_checkpoint(index=i) for i in range(3)]
    for cp in checkpoints:
        store.publish(cp, sign_envelope(build_statement(cp), private))
    recovered = [checkpoint_from_envelope(e, public) for e in store.fetch_all()]
    assert [cp.index for cp in recovered] == [0, 1, 2]


def test_file_store_refuses_to_overwrite_an_anchor(tmp_path, keypair):
    """Silently replacing a published anchor is the local-filesystem version of
    a force-push, and it is the one thing this store must not make easy."""
    private, _ = keypair
    store = FileAnchorStore(tmp_path / "anchors")
    cp = _checkpoint()
    store.publish(cp, sign_envelope(build_statement(cp), private))
    with pytest.raises(AnchorError):
        store.publish(cp, sign_envelope(build_statement(cp), private))


def test_file_store_on_a_missing_directory_is_empty_not_an_error(tmp_path):
    assert FileAnchorStore(tmp_path / "nope").fetch_all() == []


# ══════════════════════════════════════════════════════════════════════════════
# Archivista transport, against a stub implementing the documented endpoints
# ══════════════════════════════════════════════════════════════════════════════


class _StubArchivista(BaseHTTPRequestHandler):
    envelopes: dict = {}

    def log_message(self, *args):
        pass

    def _respond(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/health":
            return self._respond({"status": "ok"})
        if self.path.startswith("/download/"):
            gitoid = self.path.rsplit("/", 1)[-1]
            return self._respond(self.envelopes[gitoid])
        self.send_error(404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/upload":
            import hashlib

            envelope = json.loads(body)
            gitoid = hashlib.sha256(body).hexdigest()
            self.envelopes[gitoid] = envelope
            return self._respond({"gitoid": gitoid})
        if self.path == "/query":
            prefix = json.loads(body)["variables"]["prefix"]
            import base64

            edges = []
            for gitoid, envelope in self.envelopes.items():
                statement = json.loads(base64.b64decode(envelope["payload"]))
                if statement["subject"][0]["name"].startswith(prefix):
                    edges.append({"node": {"gitoidSha256": gitoid}})
            return self._respond({"data": {"dsses": {"edges": edges}}})
        self.send_error(404)


@pytest.fixture
def stub_archivista():
    _StubArchivista.envelopes = {}
    server = HTTPServer(("127.0.0.1", 0), _StubArchivista)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def test_archivista_health_check(stub_archivista):
    assert ArchivistaAnchorStore(stub_archivista).health()


def test_archivista_health_check_is_false_when_unreachable():
    assert not ArchivistaAnchorStore("http://127.0.0.1:1").health()


def test_archivista_round_trips(stub_archivista, keypair):
    private, public = keypair
    store = ArchivistaAnchorStore(stub_archivista)
    for i in range(3):
        cp = _checkpoint(index=i)
        assert store.publish(cp, sign_envelope(build_statement(cp), private))
    recovered = sorted(
        (checkpoint_from_envelope(e, public) for e in store.fetch_all()),
        key=lambda cp: cp.index,
    )
    assert [cp.index for cp in recovered] == [0, 1, 2]


def test_archivista_publish_surfaces_an_unreachable_server(keypair):
    private, _ = keypair
    cp = _checkpoint()
    with pytest.raises(AnchorError, match="unreachable"):
        ArchivistaAnchorStore("http://127.0.0.1:1").publish(
            cp, sign_envelope(build_statement(cp), private)
        )
