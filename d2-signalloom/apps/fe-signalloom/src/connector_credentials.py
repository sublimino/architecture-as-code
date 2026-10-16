"""Connector credentials at rest: AES-256-GCM, bound to (tenant, connector).

A tenant's connector credentials (an Anthropic API key, a GitHub token) are
stored in ``public.tenant_connectors.credentials_ciphertext`` only as the
output of :func:`seal_credentials`. The wire format is the one
``tenant_transit`` already uses for aes256-gcm96,
``vault:v1:<base64(nonce || ciphertext || tag)>``, with a fresh 96-bit nonce per
seal. The associated data names the tenant and the connector, so a ciphertext
copied onto another tenant's row (or another connector's) fails authentication
instead of decrypting.

The key is 32 bytes, hex-encoded, in the file named by
``CONNECTOR_CREDENTIAL_KEY_FILE`` (the Secret ``fe-signalloom-connector-
credential-key`` minted by ``scripts/connector-credential-key.sh`` and mounted
by ``apps/fe-signalloom/base/deployment.yaml``). It is read on every call. No
key, an unreadable file or a malformed key raises
:class:`CredentialStoreUnavailable`; there is no plaintext fallback and no
process-random key, because either would write credentials nothing could read
after the next restart, or read them back in the clear.

Rotating the key makes every stored ciphertext unreadable (tenants re-enter
their credentials); the mint script therefore never replaces an existing key.
"""
from __future__ import annotations

import base64
import json
import os
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from tenant_transit import CIPHERTEXT_PREFIX, KEY_BYTES, NONCE_BYTES, TransitDecryptError, parse_ciphertext

KEY_FILE_ENV = "CONNECTOR_CREDENTIAL_KEY_FILE"
_AAD_DOMAIN = b"signalloom.connector-credentials.v1"


class CredentialStoreUnavailable(Exception):
    """No usable key: credentials can be neither sealed nor opened."""


class CredentialDecryptError(Exception):
    """The ciphertext does not authenticate for this tenant, connector and key."""


def _key() -> bytes:
    path = os.environ.get(KEY_FILE_ENV, "").strip()
    if not path:
        raise CredentialStoreUnavailable(f"{KEY_FILE_ENV} is not set")
    try:
        with open(path, encoding="ascii") as fh:
            text = fh.read().strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise CredentialStoreUnavailable(f"the key file named by {KEY_FILE_ENV} is unreadable ({type(exc).__name__})") from None
    try:
        key = bytes.fromhex(text)
    except ValueError:
        key = b""
    if len(key) != KEY_BYTES:
        raise CredentialStoreUnavailable(f"the key file named by {KEY_FILE_ENV} does not hold {KEY_BYTES} hex-encoded bytes")
    return key


def _aad(tenant_id: str, connector_id: str) -> bytes:
    return b"\x00".join((_AAD_DOMAIN, tenant_id.encode("utf-8"), connector_id.encode("utf-8")))


def require_key() -> None:
    """Raise :class:`CredentialStoreUnavailable` unless a usable key is configured."""
    _key()


def seal_credentials(tenant_id: str, connector_id: str, credentials: dict[str, str]) -> str:
    aead = AESGCM(_key())
    nonce = secrets.token_bytes(NONCE_BYTES)
    plaintext = json.dumps(credentials, sort_keys=True, separators=(",", ":")).encode("utf-8")
    sealed = aead.encrypt(nonce, plaintext, _aad(tenant_id, connector_id))
    return CIPHERTEXT_PREFIX + base64.b64encode(nonce + sealed).decode("ascii")


def open_credentials(tenant_id: str, connector_id: str, ciphertext: str) -> dict[str, str]:
    aead = AESGCM(_key())
    try:
        raw = parse_ciphertext(ciphertext)
        plaintext = aead.decrypt(raw[:NONCE_BYTES], raw[NONCE_BYTES:], _aad(tenant_id, connector_id))
    except (TransitDecryptError, InvalidTag):
        raise CredentialDecryptError("stored connector credentials do not authenticate under the configured key") from None
    decoded = json.loads(plaintext)
    return {str(k): str(v) for k, v in decoded.items()}
