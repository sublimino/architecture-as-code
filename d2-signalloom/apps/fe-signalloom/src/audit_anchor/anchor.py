"""Build signed DSSE checkpoints and persist them as local evidence.

Hash chaining alone does not prevent history rewriting. This module therefore
combines signatures, checkpoint back-links, Merkle roots, and protected
high-water state so an independent verifier can detect tampering and rollback.

``FileAnchorStore`` writes the signed envelopes to a directory. This is not
external custody or a transparency-log inclusion proof. Its independence is
limited by filesystem permissions and by how operators separate the evidence,
trusted public keys, and protected high-water material from the producer.
"""
import base64
import hashlib
import json
import os
import urllib.error
import urllib.request
from pathlib import Path

from audit_anchor.checkpoint import PREDICATE_TYPE, Checkpoint

IN_TOTO_STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
DSSE_PAYLOAD_TYPE = "application/vnd.in-toto+json"


class AnchorError(Exception):
    pass


class IntegrityError(AnchorError):
    """Cryptographic or persisted evidence proves divergence."""


# ══════════════════════════════════════════════════════════════════════════════
# DSSE
# ══════════════════════════════════════════════════════════════════════════════


def pae(payload_type: str, payload: bytes) -> bytes:
    """DSSE Pre-Authentication Encoding.

        "DSSEv1" SP len(type) SP type SP len(payload) SP payload

    Length-prefixed for the same reason canonical.encode_field is: so that no
    choice of field content can move a boundary and make one message
    authenticate as another. The signature is over this, never over the raw
    payload -- signing the payload alone would let an envelope be replayed under
    a different payloadType.
    """
    type_bytes = payload_type.encode("utf-8")
    return b"DSSEv1 %d %s %d %s" % (len(type_bytes), type_bytes, len(payload), payload)


def build_statement(checkpoint: Checkpoint) -> dict:
    """An in-toto Statement whose subject IS the checkpoint digest.

    The subject digest is the checkpoint digest, so the envelope binds the
    signature to the exact checkpoint contents. The name is stable and ordered
    so anchors can be enumerated and re-sequenced from the log alone.
    """
    return {
        "_type": IN_TOTO_STATEMENT_TYPE,
        "subject": [
            {
                "name": checkpoint.subject_name(),
                "digest": {"sha256": checkpoint.digest()},
            }
        ],
        "predicateType": PREDICATE_TYPE,
        "predicate": checkpoint.to_predicate(),
    }


def _read_key(path, kind: str) -> bytes:
    """Read a key file, reporting the RESOLVED absolute path when it is missing.

    Reporting the resolved path rather than the argument is what makes a
    mis-joined path self-diagnosing. The shipped bug in the tamper demo passed

        /tmp/osramp-wt/<worktree>/home/andy/src/cp/osramp-demo/.keys/witness.pem

    -- a repo root with an absolute path concatenated onto it, the leading slash
    swallowed. Printed in full it is instantly obvious; described as "key not
    found" it is a twenty-minute hunt. Path handling for these arguments is
    otherwise deliberately plain: an absolute path is honoured as absolute and a
    relative one resolves against the working directory, which is what
    pathlib already does and what callers expect.
    """
    resolved = Path(path).expanduser()
    try:
        return resolved.read_bytes()
    except FileNotFoundError:
        raise AnchorError(
            f"{kind} key not found at {resolved.absolute()}"
            + (f" (requested as {path})" if str(resolved) != str(path) else "")
            + "\n  .keys/ is gitignored and therefore per-checkout, so a fresh worktree "
            "has none.\n  Generate one with `make signing-keys`, or point KEYS_DIR at "
            "the checkout that holds it."
        ) from None
    except IsADirectoryError:
        raise AnchorError(f"{kind} key path {resolved.absolute()} is a directory") from None


def load_private_key(path):
    from cryptography.hazmat.primitives.serialization import load_pem_private_key

    return load_pem_private_key(_read_key(path, "private"), password=None)


def load_public_key(path):
    from cryptography.hazmat.primitives.serialization import load_pem_public_key

    return load_pem_public_key(_read_key(path, "public"))


def key_id(public_key) -> str:
    """SHA256 over the DER SubjectPublicKeyInfo -- the usual DSSE keyid shape."""
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    der = public_key.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    return hashlib.sha256(der).hexdigest()


def sign_envelope(statement: dict, private_key) -> dict:
    # sort_keys + compact separators so the payload bytes are reproducible from
    # the statement. The signature covers these exact bytes, so a verifier reads
    # the payload it was handed rather than re-serialising and hoping.
    payload = json.dumps(statement, sort_keys=True, separators=(",", ":")).encode("utf-8")
    signature = private_key.sign(pae(DSSE_PAYLOAD_TYPE, payload))
    return {
        "payloadType": DSSE_PAYLOAD_TYPE,
        "payload": base64.b64encode(payload).decode("ascii"),
        "signatures": [
            {
                "keyid": key_id(private_key.public_key()),
                "sig": base64.b64encode(signature).decode("ascii"),
            }
        ],
    }


def verify_envelope(envelope: dict, public_key, expected_key_id: str | None = None) -> dict:
    """Check the signature and return the Statement. Raises if it does not verify.

    Raises rather than returning a bool: every caller needs the payload, and a
    caller that gets a payload plus a bool it can forget to check is a caller
    that will forget to check.
    """
    from cryptography.exceptions import InvalidSignature

    expected_key_id = expected_key_id or key_id(public_key)
    payload = base64.b64decode(envelope["payload"])
    to_verify = pae(envelope["payloadType"], payload)
    for signature in envelope.get("signatures", []):
        if signature.get("keyid") != expected_key_id:
            continue
        try:
            public_key.verify(base64.b64decode(signature["sig"]), to_verify)
            return json.loads(payload)
        except InvalidSignature:
            continue
    raise IntegrityError(
        "no signature on this envelope verifies against the supplied public key -- "
        "the anchor was signed by a different key, or it has been altered"
    )


def checkpoint_from_envelope(envelope: dict, public_key) -> Checkpoint:
    """Verify, then re-derive the checkpoint and confirm it matches the subject.

    The second check is the one that matters. Without it a signed envelope could
    carry a predicate whose digest does not match its own subject, and the
    subject is what the chain's back-links point at.
    """
    statement = verify_envelope(envelope, public_key)
    if statement.get("predicateType") != PREDICATE_TYPE:
        raise AnchorError(f"unexpected predicateType {statement.get('predicateType')!r}")
    checkpoint = Checkpoint.from_predicate(statement["predicate"])
    subject_digest = statement["subject"][0]["digest"]["sha256"]
    if checkpoint.digest() != subject_digest:
        raise IntegrityError(
            f"checkpoint {checkpoint.index} re-derives to {checkpoint.digest()[:16]}... "
            f"but its signed subject says {subject_digest[:16]}...; the predicate and "
            "the subject disagree"
        )
    return checkpoint


# ══════════════════════════════════════════════════════════════════════════════
# Transports
# ══════════════════════════════════════════════════════════════════════════════


class FileAnchorStore:
    """Envelopes as files in a directory.

    This is local evidence, not an external transparency log. Its custody is
    determined by filesystem permissions and operational separation.
    """

    def __init__(self, directory):
        self.directory = Path(directory)

    def publish(self, checkpoint: Checkpoint, envelope: dict) -> str:
        self.directory.mkdir(parents=True, exist_ok=True)
        name = f"{checkpoint.index:08d}-{checkpoint.digest()[:12]}.dsse.json"
        path = self.directory / name
        if path.exists():
            raise AnchorError(f"{path} already exists; refusing to overwrite an anchor")
        path.write_text(json.dumps(envelope, indent=2, sort_keys=True) + "\n")
        return str(path)

    def fetch_all(self, subject_prefix: str | None = None) -> list:
        if not self.directory.exists():
            return []
        envelopes = [
            json.loads(path.read_text())
            for path in sorted(self.directory.glob("*.dsse.json"))
        ]
        if subject_prefix is None:
            return envelopes
        selected = []
        for envelope in envelopes:
            try:
                statement = json.loads(base64.b64decode(envelope["payload"]))
                name = statement["subject"][0]["name"]
            except (KeyError, IndexError, ValueError, json.JSONDecodeError) as exc:
                raise AnchorError(f"malformed anchor envelope while selecting subjects: {exc}")
            if name.startswith(subject_prefix):
                selected.append(envelope)
        return selected


def store_from_env():
    """Return local evidence storage and reject removed configuration."""
    stale = [
        name
        for name in ("ARCHIVISTA_URL", "AUDIT_ANCHOR_REQUIRE_LOG")
        if os.environ.get(name)
    ]
    if stale:
        raise AnchorError(
            "Archivista support was removed; unset stale configuration: "
            + ", ".join(stale)
        )
    directory = os.environ.get("AUDIT_ANCHOR_DIR", "vex/out/audit-anchors")
    return FileAnchorStore(directory), f"file:{directory}"


def require_rekor_if_configured(timeout: int = 10) -> None:
    """Reject configured Rekor until publication and inclusion verification exist.

    Connectivity is not anchoring. This slice uses protected local high-water
    state; it must never claim Rekor extended its trust boundary.
    """
    url = os.environ.get("REKOR_URL")
    if not url:
        return
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/api/v1/log", timeout=timeout) as response:
            if response.status != 200:
                raise AnchorError(f"Rekor at {url} returned HTTP {response.status}")
    except (urllib.error.URLError, TimeoutError) as exc:
        raise AnchorError(f"Rekor at {url} unavailable: {exc}") from exc
    raise AnchorError("Rekor anchoring is not implemented; no checkpoint was published to Rekor")
