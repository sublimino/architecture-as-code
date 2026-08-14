"""Publication: turn a checkpoint into a signed DSSE envelope and put it
somewhere the application's database role cannot reach.

WHY THIS PART IS THE CONTROL

Hash-chaining rows does not prevent tampering, it detects it -- and only if the
chain head is published somewhere the tamperer cannot reach.  Git makes the
point unavoidably: ``git commit --amend`` plus a force-push rewrites history and
every hash downstream of it, and the only reason anyone notices is that other
people hold clones.  An anchor that lives in the same database as the rows is a
clone held by the same person.  It buys nothing.

So the property to preserve is narrow and specific: REWRITING HISTORY MUST ALSO
REQUIRE REWRITING THE ANCHOR, AND THE ANCHOR MUST NOT BE IN THE ATTACKER'S
CONTROL.  Everything else here is packaging.

WHAT WE REUSED, AND WHY

This repository already runs in-toto attestation infrastructure.
``scripts/attested-test.sh`` runs the test suite under ``witness``, signs the
result with ``.keys/witness.pem``, and pushes the DSSE envelope into Archivista
at ``svc/osramp-archivista`` in the backend namespace.  ControlPlane sponsors
Witness and Archivista.

We therefore emit exactly what that pipeline already carries -- an in-toto
Statement in a DSSE envelope, signed with the same ed25519 key -- rather than
inventing a checkpoint file format and a signing scheme to go with it.  Two
consequences worth stating.  First, no new dependency: DSSE is a length-prefixed
encoding and an ed25519 signature, and ``cryptography`` is already present via
PyJWT[crypto].  Second, the audit trail ends up witnessed by the same
attestation infrastructure the organisation already sponsors for supply chain,
which is a considerably better story than a bespoke hash file.

TRANSPORTS

``ArchivistaAnchorStore`` is the intended anchor.  Archivista holds its own
MySQL and MinIO in a different namespace under different credentials; the
signalloom Postgres role has no route to it.

``FileAnchorStore`` writes the identical envelope bytes to a directory.  It is a
fallback, and a weaker one -- its strength is entirely the filesystem
permissions on that directory.  It is not a different format: the same file can
be POSTed to Archivista unchanged once the backend slice is deployed.
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


def verify_envelope(envelope: dict, public_key) -> dict:
    """Check the signature and return the Statement. Raises if it does not verify.

    Raises rather than returning a bool: every caller needs the payload, and a
    caller that gets a payload plus a bool it can forget to check is a caller
    that will forget to check.
    """
    from cryptography.exceptions import InvalidSignature

    payload = base64.b64decode(envelope["payload"])
    to_verify = pae(envelope["payloadType"], payload)
    for signature in envelope.get("signatures", []):
        try:
            public_key.verify(base64.b64decode(signature["sig"]), to_verify)
            return json.loads(payload)
        except InvalidSignature:
            continue
    raise AnchorError(
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
        raise AnchorError(
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

    Weaker than a transparency log and it should be said plainly: its only
    strength is the filesystem permissions on the directory. It is here so the
    control still functions where Archivista is not deployed, and because the
    bytes are identical -- the same files upload to Archivista unchanged.
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

    def fetch_all(self) -> list:
        if not self.directory.exists():
            return []
        return [
            json.loads(path.read_text())
            for path in sorted(self.directory.glob("*.dsse.json"))
        ]


class ArchivistaAnchorStore:
    """Envelopes in Archivista -- the intended anchor.

    Archivista keeps its own MySQL and MinIO in the backend namespace under
    separate credentials, so the signalloom Postgres role cannot reach it. It is
    also content-addressed: an envelope is stored under the gitoid of its own
    bytes, so altering a stored anchor changes its address rather than its
    contents.

    Uses urllib rather than adding an HTTP client dependency. The API surface is
    three endpoints and the payloads are small.
    """

    def __init__(self, base_url: str, timeout: int = 30):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _post(self, path: str, body: bytes, content_type: str) -> str:
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers={"Content-Type": content_type},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read().decode("utf-8")
        except urllib.error.URLError as exc:
            raise AnchorError(f"Archivista at {self.base_url} unreachable: {exc}") from exc

    def health(self) -> bool:
        try:
            with urllib.request.urlopen(
                f"{self.base_url}/v1/health", timeout=self.timeout
            ) as response:
                return response.status == 200
        except urllib.error.URLError:
            return False

    def publish(self, checkpoint: Checkpoint, envelope: dict) -> str:
        raw = self._post(
            "/upload", json.dumps(envelope).encode("utf-8"), "application/json"
        )
        try:
            return json.loads(raw).get("gitoid", raw.strip())
        except json.JSONDecodeError:
            # Archivista returns the bare gitoid as text/plain on some versions.
            return raw.strip()

    def _gitoids(self, subject_prefix: str) -> list:
        query = {
            "query": (
                "query($prefix: String!) { dsses(where: {hasStatementWith: "
                "{hasSubjectsWith: {nameHasPrefix: $prefix}}}) "
                "{ edges { node { gitoidSha256 } } } }"
            ),
            "variables": {"prefix": subject_prefix},
        }
        raw = self._post("/query", json.dumps(query).encode("utf-8"), "application/json")
        payload = json.loads(raw)
        if "errors" in payload:
            raise AnchorError(f"Archivista query failed: {payload['errors']}")
        edges = payload["data"]["dsses"]["edges"]
        return [edge["node"]["gitoidSha256"] for edge in edges]

    def fetch_all(self, subject_prefix: str = "signalloom-audit-checkpoint/") -> list:
        envelopes = []
        for gitoid in self._gitoids(subject_prefix):
            with urllib.request.urlopen(
                f"{self.base_url}/download/{gitoid}", timeout=self.timeout
            ) as response:
                envelopes.append(json.loads(response.read()))
        return envelopes


def store_from_env():
    """Pick a transport. Archivista when it answers, files otherwise.

    Fails over rather than failing hard, but the CLI always prints which one it
    used: a checkpoint anchored to a local directory and one anchored to a
    transparency log are not the same evidence, and the operator must not have
    to guess which they have.
    """
    url = os.environ.get("ARCHIVISTA_URL")
    if url:
        store = ArchivistaAnchorStore(url)
        if store.health():
            return store, f"archivista:{url}"
        return (
            FileAnchorStore(os.environ.get("AUDIT_ANCHOR_DIR", "vex/out/audit-anchors")),
            f"file (ARCHIVISTA_URL={url} did not answer)",
        )
    directory = os.environ.get("AUDIT_ANCHOR_DIR", "vex/out/audit-anchors")
    return FileAnchorStore(directory), f"file:{directory}"
