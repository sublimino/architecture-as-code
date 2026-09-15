# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
SLDP Pseudonym primitive for Python.

Matches the cryptographic contract of Go package `d2-signalloom/apps/signal-ingest/pseudonym`.
Provides deterministic, tenant-and-epoch-scoped HMAC-SHA256 pseudonyms derived via HKDF-SHA256
from a root key.
"""
from __future__ import annotations

import hashlib
import hmac
import struct
import threading
from typing import Dict, Optional, Union

# Domain is the version-pinned domain-separation label bound into every derived pseudonym key.
DOMAIN: bytes = b"signalloom/identity/alias-pseudonym/v1"

# MinRootKeyBytes is the minimum accepted root key material length.
MIN_ROOT_KEY_BYTES: int = 32

# HexLen is the length of a hex-encoded HMAC-SHA256 pseudonym.
HEX_LEN: int = 64


class PseudonymError(Exception):
    """Base exception for pseudonym errors."""
    pass


class RootKeyTooShortError(PseudonymError):
    """Raised when root key material is absent or under-length."""
    pass


class TenantRequiredError(PseudonymError):
    """Raised when no tenant scope is supplied."""
    pass


class ValueRequiredError(PseudonymError):
    """Raised when the value to pseudonymise is empty."""
    pass


def derive_info(epoch: int, tenant_id: str) -> bytes:
    """
    Build the HKDF info parameter according to the SLDP contract:
      - 4-byte big-endian uint32 domain length
      - domain bytes
      - 4-byte big-endian uint32 epoch
      - 4-byte big-endian uint32 tenant_id length
      - tenant_id UTF-8 bytes
    """
    tenant_bytes = tenant_id.encode("utf-8")
    return (
        struct.pack(">I", len(DOMAIN))
        + DOMAIN
        + struct.pack(">I", epoch)
        + struct.pack(">I", len(tenant_bytes))
        + tenant_bytes
    )


def hkdf_sha256(root: bytes, info: bytes, length: int = 32) -> bytes:
    """
    RFC 5869 HKDF-SHA256 key derivation matching Go `crypto/hkdf`.
    Salt is nil (represented as 32 zero bytes in HKDF-Extract).
    """
    salt = b"\x00" * 32
    # Extract
    prk = hmac.new(salt, root, hashlib.sha256).digest()
    # Expand (length <= 32 bytes fits in single block T(1))
    t1 = hmac.new(prk, info + b"\x01", hashlib.sha256).digest()
    return t1[:length]


class KeyRing:
    """
    KeyRing derives per-tenant, per-epoch pseudonymisation keys from root key material
    and computes keyed HMAC-SHA256 pseudonyms with them.
    """

    def __init__(self, root: bytes, epoch: int = 1) -> None:
        if len(root) < MIN_ROOT_KEY_BYTES:
            raise RootKeyTooShortError(
                f"identity: pseudonym root key must be at least {MIN_ROOT_KEY_BYTES} bytes"
            )
        self._root: bytes = bytes(root)
        self._epoch: int = int(epoch)
        self._derived: Dict[str, bytes] = {}
        self._lock = threading.Lock()

    @property
    def epoch(self) -> int:
        return self._epoch

    def tenant_key(self, tenant_id: str) -> bytes:
        """Derive and cache the HKDF tenant key."""
        if not tenant_id:
            raise TenantRequiredError("identity: pseudonym tenant identifier is required")
        with self._lock:
            if tenant_id in self._derived:
                return self._derived[tenant_id]
            info = derive_info(self._epoch, tenant_id)
            key = hkdf_sha256(self._root, info, 32)
            self._derived[tenant_id] = key
            return key

    def pseudonym(self, tenant_id: str, value: Union[str, bytes, bytearray]) -> str:
        """
        Compute the hex-encoded HMAC-SHA256 pseudonym for value under tenant_id.
        Fails closed on empty tenant_id or empty value.
        """
        if not tenant_id:
            raise TenantRequiredError("identity: pseudonym tenant identifier is required")
        if not value:
            raise ValueRequiredError("identity: pseudonym input value is required")

        key = self.tenant_key(tenant_id)
        if isinstance(value, str):
            val_bytes = value.encode("utf-8")
        elif isinstance(value, (bytes, bytearray, memoryview)):
            val_bytes = bytes(value)
        else:
            val_bytes = str(value).encode("utf-8")

        if len(val_bytes) == 0:
            raise ValueRequiredError("identity: pseudonym input value is required")

        mac = hmac.new(key, val_bytes, hashlib.sha256)
        return mac.hexdigest()

    def is_tenant_key_cached(self, tenant_id: str) -> bool:
        """Check if tenant key is memoised in memory."""
        with self._lock:
            return tenant_id in self._derived


def is_pseudonym(s: str) -> bool:
    """Check whether a string has the exact shape of a 64-character lowercase hex pseudonym."""
    if len(s) != HEX_LEN:
        return False
    for char in s:
        if not (("0" <= char <= "9") or ("a" <= char <= "f")):
            return False
    return True


# Default shared KeyRing for host sensor operations
DEFAULT_ROOT_KEY = b"signalloom-host-sensor-root-key-material-2026-v1"
DEFAULT_KEYRING = KeyRing(DEFAULT_ROOT_KEY, epoch=1)
