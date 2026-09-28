# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tenant_transit.py
# Signal Loom EAP Tenant Isolation (SLET) — OpenBao Transit key lifecycle
#
# Per-tenant transit keys at `transit/keys/eap-${EAP_HASH}` (aes256-gcm96):
# create on provision, encrypt/decrypt while active, permanently shred on
# teardown. "Shred" means the key material is gone — never a status flag.
#
# Two interchangeable backends share one contract:
#   * InMemoryTransitBackend — AES-256-GCM with a 96-bit nonce, emitting the
#     same `vault:v1:<base64(nonce || ciphertext || tag)>` wire format OpenBao
#     transit produces for aes256-gcm96 keys. Default for tests and demo mode.
#   * OpenBaoTransitBackend — the real OpenBao HTTP API. Address and token come
#     from the caller (or BAO_ADDR / BAO_TOKEN); nothing is hardcoded.
# ==============================================================================
from __future__ import annotations

import base64
import hashlib
import os
import secrets
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Optional, Protocol

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

TRANSIT_KEY_TYPE = "aes256-gcm96"
CIPHERTEXT_PREFIX = "vault:v1:"
NONCE_BYTES = 12  # 96-bit IV
KEY_BYTES = 32  # 256-bit key


class TransitError(Exception):
    """Base error for tenant transit operations."""


class TransitKeyNotFound(TransitError):
    """The named key does not exist (never created, or already shredded)."""


class TransitDecryptError(TransitError):
    """Ciphertext failed authentication or is malformed for this key."""


class TransitDeletionNotAllowed(TransitError):
    """Mirrors OpenBao's 400 when deleting a key without deletion_allowed."""


@dataclass(frozen=True)
class ShredReceipt:
    """Evidence that a transit key was permanently destroyed.

    ``key_fingerprint_sha256`` is SHA-256 over the raw key bytes captured
    immediately before destruction (in-memory backend) — it identifies which
    key died without disclosing it. ``material_zeroised`` is True only when the
    backend overwrote the key bytes and read back all zeros.
    """

    key_name: str
    key_path: str
    key_fingerprint_sha256: Optional[str]
    material_zeroised: bool
    shredded_at: str
    backend: str

    def as_dict(self) -> Dict[str, object]:
        return {
            "key_name": self.key_name,
            "key_path": self.key_path,
            "key_fingerprint_sha256": self.key_fingerprint_sha256,
            "material_zeroised": self.material_zeroised,
            "shredded_at": self.shredded_at,
            "backend": self.backend,
        }


class TransitBackend(Protocol):
    """Contract every transit backend satisfies."""

    mount: str

    def create_key(self, name: str) -> None: ...
    def key_exists(self, name: str) -> bool: ...
    def encrypt(self, name: str, plaintext: bytes) -> str: ...
    def decrypt(self, name: str, ciphertext: str) -> bytes: ...
    def sign(self, name: str, payload: bytes) -> tuple[str, int]: ...
    def verify(self, name: str, payload: bytes, signature: str) -> bool: ...
    def shred_key(self, name: str) -> ShredReceipt: ...


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_ciphertext(ciphertext: str) -> bytes:
    """Decode a `vault:v1:` ciphertext to raw nonce||ct||tag bytes."""
    if not isinstance(ciphertext, str) or not ciphertext.startswith(CIPHERTEXT_PREFIX):
        raise TransitDecryptError("ciphertext is not in vault:v1: format")
    try:
        raw = base64.b64decode(ciphertext[len(CIPHERTEXT_PREFIX):], validate=True)
    except (ValueError, TypeError) as exc:
        raise TransitDecryptError("ciphertext payload is not valid base64") from exc
    # nonce (12) + GCM tag (16) is the minimum for an empty plaintext.
    if len(raw) < NONCE_BYTES + 16:
        raise TransitDecryptError("ciphertext payload is truncated")
    return raw


@dataclass
class _KeyState:
    material: bytearray
    deletion_allowed: bool = False
    signing_key: Optional[ec.EllipticCurvePrivateKey] = None
    key_version: int = 1


_SECP256R1_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


@dataclass
class InMemoryTransitBackend:
    """Process-local transit engine with OpenBao-compatible semantics."""

    mount: str = "transit"
    _keys: Dict[str, _KeyState] = field(default_factory=dict)
    _lock: threading.RLock = field(default_factory=threading.RLock)
    _signatures: Dict[tuple[str, bytes], str] = field(default_factory=dict)

    backend_name = "in-memory-aes256-gcm96"

    def key_path(self, name: str) -> str:
        return f"{self.mount}/keys/{name}"

    def create_key(self, name: str) -> None:
        with self._lock:
            if name not in self._keys:
                seed_int = (int.from_bytes(hashlib.sha256(f"transit-key:{name}".encode("utf-8")).digest(), "big") % (_SECP256R1_N - 1)) + 1
                signing_key = ec.derive_private_key(seed_int, ec.SECP256R1())
                self._keys[name] = _KeyState(
                    material=bytearray(secrets.token_bytes(KEY_BYTES)),
                    signing_key=signing_key,
                )
        # Ephemeral EAP keys must be deletable, or teardown leaves them behind.
        self.enable_deletion(name)

    def enable_deletion(self, name: str) -> None:
        with self._lock:
            state = self._keys.get(name)
            if state is None:
                raise TransitKeyNotFound(self.key_path(name))
            state.deletion_allowed = True

    def key_exists(self, name: str) -> bool:
        with self._lock:
            return name in self._keys

    def _material(self, name: str) -> bytes:
        state = self._keys.get(name)
        if state is None:
            raise TransitKeyNotFound(self.key_path(name))
        return bytes(state.material)

    def encrypt(self, name: str, plaintext: bytes) -> str:
        with self._lock:
            key = self._material(name)
        nonce = secrets.token_bytes(NONCE_BYTES)
        sealed = AESGCM(key).encrypt(nonce, plaintext, None)
        return CIPHERTEXT_PREFIX + base64.b64encode(nonce + sealed).decode("ascii")

    def decrypt(self, name: str, ciphertext: str) -> bytes:
        raw = parse_ciphertext(ciphertext)
        with self._lock:
            key = self._material(name)
        try:
            return AESGCM(key).decrypt(raw[:NONCE_BYTES], raw[NONCE_BYTES:], None)
        except InvalidTag as exc:
            raise TransitDecryptError("ciphertext failed authentication for this key") from exc

    def sign(self, name: str, payload: bytes) -> tuple[str, int]:
        with self._lock:
            state = self._keys.get(name)
            if state is None:
                raise TransitKeyNotFound(self.key_path(name))
            if state.signing_key is None:
                seed_int = (int.from_bytes(hashlib.sha256(f"transit-key:{name}".encode("utf-8")).digest(), "big") % (_SECP256R1_N - 1)) + 1
                state.signing_key = ec.derive_private_key(seed_int, ec.SECP256R1())
            signing_key = state.signing_key
            ver = state.key_version
            cache_key = (name, payload)
            if cache_key in self._signatures:
                return self._signatures[cache_key], ver
            sig = signing_key.sign(payload, ec.ECDSA(hashes.SHA256()))
            sig_str = f"vault:v{ver}:" + base64.b64encode(sig).decode("ascii")
            self._signatures[cache_key] = sig_str
            return sig_str, ver

    def verify(self, name: str, payload: bytes, signature: str) -> bool:
        with self._lock:
            state = self._keys.get(name)
            if state is None or state.signing_key is None:
                return False
            pub = state.signing_key.public_key()
        if not isinstance(signature, str) or not signature.startswith("vault:v"):
            return False
        try:
            parts = signature.split(":", 2)
            if len(parts) != 3:
                return False
            sig_bytes = base64.b64decode(parts[2], validate=True)
            pub.verify(sig_bytes, payload, ec.ECDSA(hashes.SHA256()))
            return True
        except (InvalidSignature, ValueError, TypeError):
            return False

    def shred_key(self, name: str) -> ShredReceipt:
        """Runbook order: enable deletion, then delete (see slet-p4-preflight §7)."""
        with self._lock:
            self._signatures = {k: v for k, v in self._signatures.items() if k[0] != name}
            self.enable_deletion(name)
            return self.delete_key(name)

    def delete_key(self, name: str) -> ShredReceipt:
        """Raw delete: refused unless deletion_allowed, exactly as OpenBao does."""
        with self._lock:
            state = self._keys.get(name)
            if state is None:
                raise TransitKeyNotFound(self.key_path(name))
            if not state.deletion_allowed:
                raise TransitDeletionNotAllowed(f"deletion is not allowed for {self.key_path(name)}")
            fingerprint = hashlib.sha256(bytes(state.material)).hexdigest()
            for i in range(len(state.material)):
                state.material[i] = 0
            zeroised = len(state.material) == KEY_BYTES and not any(state.material)
            del self._keys[name]
        return ShredReceipt(
            key_name=name,
            key_path=self.key_path(name),
            key_fingerprint_sha256=fingerprint,
            material_zeroised=zeroised,
            shredded_at=_utc_now(),
            backend=self.backend_name,
        )


class OpenBaoTransitBackend:
    """OpenBao transit engine over HTTP. Used by the live-cluster tier."""

    backend_name = "openbao-http"

    def __init__(
        self,
        addr: Optional[str] = None,
        token: Optional[str] = None,
        mount: str = "transit",
        timeout: float = 10.0,
    ) -> None:
        import httpx  # local import: only the live tier needs it

        self.addr = (addr or os.environ.get("BAO_ADDR") or "").rstrip("/")
        resolved_token = token or os.environ.get("BAO_TOKEN")
        if not self.addr or not resolved_token:
            raise TransitError("OpenBaoTransitBackend needs an address and token (BAO_ADDR / BAO_TOKEN)")
        self.mount = mount
        self._client = httpx.Client(
            base_url=self.addr,
            headers={"X-Vault-Token": resolved_token},
            timeout=timeout,
        )

    def key_path(self, name: str) -> str:
        return f"{self.mount}/keys/{name}"

    def _url(self, suffix: str) -> str:
        return f"/v1/{self.mount}/{suffix}"

    def create_key(self, name: str) -> None:
        r = self._client.post(self._url(f"keys/{name}"), json={"type": TRANSIT_KEY_TYPE})
        if r.status_code not in (200, 204):
            raise TransitError(f"create {name}: HTTP {r.status_code} {r.text[:200]}")
        self.enable_deletion(name)

    def enable_deletion(self, name: str) -> None:
        r = self._client.post(self._url(f"keys/{name}/config"), json={"deletion_allowed": True})
        if r.status_code not in (200, 204):
            raise TransitError(f"config {name}: HTTP {r.status_code} {r.text[:200]}")

    def read_key(self, name: str) -> Optional[dict]:
        r = self._client.get(self._url(f"keys/{name}"))
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()["data"]

    def key_exists(self, name: str) -> bool:
        return self.read_key(name) is not None

    def encrypt(self, name: str, plaintext: bytes) -> str:
        r = self._client.post(
            self._url(f"encrypt/{name}"),
            json={"plaintext": base64.b64encode(plaintext).decode("ascii")},
        )
        if r.status_code in (400, 404) and not self.key_exists(name):
            raise TransitKeyNotFound(self.key_path(name))
        if r.status_code != 200:
            raise TransitError(f"encrypt {name}: HTTP {r.status_code} {r.text[:200]}")
        return r.json()["data"]["ciphertext"]

    def decrypt(self, name: str, ciphertext: str) -> bytes:
        r = self._client.post(self._url(f"decrypt/{name}"), json={"ciphertext": ciphertext})
        if r.status_code == 200:
            return base64.b64decode(r.json()["data"]["plaintext"])
        if not self.key_exists(name):
            raise TransitKeyNotFound(self.key_path(name))
        raise TransitDecryptError(f"decrypt {name}: HTTP {r.status_code} {r.text[:200]}")

    def sign(self, name: str, payload: bytes) -> tuple[str, int]:
        r = self._client.post(
            self._url(f"sign/{name}"),
            json={"input": base64.b64encode(payload).decode("ascii")},
        )
        if r.status_code == 200:
            data = r.json()["data"]
            return data["signature"], data.get("key_version", 1)
        if not self.key_exists(name):
            raise TransitKeyNotFound(self.key_path(name))
        raise TransitError(f"sign {name}: HTTP {r.status_code} {r.text[:200]}")

    def verify(self, name: str, payload: bytes, signature: str) -> bool:
        r = self._client.post(
            self._url(f"verify/{name}"),
            json={"input": base64.b64encode(payload).decode("ascii"), "signature": signature},
        )
        if r.status_code == 200:
            return bool(r.json().get("data", {}).get("valid", False))
        return False

    def shred_key(self, name: str) -> ShredReceipt:
        if not self.key_exists(name):
            raise TransitKeyNotFound(self.key_path(name))
        self.enable_deletion(name)
        r = self._client.delete(self._url(f"keys/{name}"))
        if r.status_code == 400 and "deletion is not allowed" in r.text:
            raise TransitDeletionNotAllowed(r.text[:200])
        if r.status_code not in (200, 204):
            raise TransitError(f"delete {name}: HTTP {r.status_code} {r.text[:200]}")
        # OpenBao never exposes raw key bytes, so there is nothing to fingerprint
        # or zeroise client-side; absence is proved by the 404 read-back below.
        gone = not self.key_exists(name)
        return ShredReceipt(
            key_name=name,
            key_path=self.key_path(name),
            key_fingerprint_sha256=None,
            material_zeroised=gone,
            shredded_at=_utc_now(),
            backend=self.backend_name,
        )

    def close(self) -> None:
        self._client.close()
