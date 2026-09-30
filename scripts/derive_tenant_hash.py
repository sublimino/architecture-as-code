#!/usr/bin/env python3
"""Canonical Signal Loom tenant domain hash (SLDC-P3-1).

    hash = sha256(salt + ":" + lower(trim(tenant))).hexdigest()[:8]

This is the salted SHA-256 concatenation the estate already implements
(`environment_routing.derive_customer_hash`, `scripts/eap/tailscale-eap-env.sh`).
It is NOT HMAC-SHA256: HMAC(salt, "kusari") is 4a89f30d, and the canonical
vector 4b53ab6b only comes from the concatenation. Governor ruling G1 on
SLDC-P3-PRE fixed the formula text to match; see Appendix C.1 of the SLDC
proposal.

Salt resolution, first hit wins:
  1. OpenBao KV v2 `secret/data/signalloom/eap`, field `salt`, when an
     address (BAO_ADDR, VAULT_ADDR or OPENBAO_ADDR) and a token (BAO_TOKEN or
     VAULT_TOKEN) are set. Two-second timeout; any failure falls through.
  2. SIGNAL_LOOM_EAP_SALT.
  3. Nothing: fail closed with exit 1. There is deliberately no built-in
     default salt, because an earlier governor removed DEFAULT_EAP_SALT.

Usage:
  derive_tenant_hash.py <tenant>          prints "Tenant: <t> -> Hash: <h>"
  derive_tenant_hash.py --quiet <tenant>  prints the bare 8-char hash
  derive_tenant_hash.py                   runs the known-answer self-test

Exit codes: 0 ok, 1 retired/invalid tenant, missing salt or self-test
failure, 2 usage error.

@id      derive-tenant-hash
@doc     docs/eap/SLDC-P3-TENANT-INVENTORY.md
@tests   test/unit/test_tenant_hash.py test/tenant-hash-vectors.bats
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Callable, Mapping, Optional

PILOT_SALT = "signalloom-eap-salt-2026-q3"
CANONICAL_TENANT = "kusari"
CANONICAL_HASH = "4b53ab6b"
RETIRED_TENANTS = frozenset({"kurasi"})
UNSALTED_KUSARI = "d9d69501"

BAO_KV_PATH = "/v1/secret/data/signalloom/eap"
BAO_TIMEOUT_SECONDS = 2.0
_ADDR_VARS = ("BAO_ADDR", "VAULT_ADDR", "OPENBAO_ADDR")
_TOKEN_VARS = ("BAO_TOKEN", "VAULT_TOKEN")
_TENANT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_HASH_RE = re.compile(r"^[0-9a-f]{8}$")


class TenantHashError(ValueError):
    """Raised for inputs the derivation must refuse (fail closed)."""


class RetiredTenantError(TenantHashError):
    """Raised for the retired legacy typo `kurasi`."""


class SaltUnavailableError(RuntimeError):
    """Raised when neither OpenBao nor SIGNAL_LOOM_EAP_SALT yields a salt."""


def normalize_tenant(tenant_name: str) -> str:
    if not isinstance(tenant_name, str):
        raise TenantHashError("tenant name must be a string")
    cleaned = tenant_name.strip().lower()
    if not cleaned:
        raise TenantHashError("tenant name cannot be empty")
    if cleaned in RETIRED_TENANTS:
        raise RetiredTenantError(
            f"tenant '{cleaned}' is a retired legacy typo; the canonical tenant is "
            f"'{CANONICAL_TENANT}'"
        )
    if not _TENANT_RE.match(cleaned):
        raise TenantHashError(
            f"invalid tenant name '{cleaned}' (must match ^[a-z0-9][a-z0-9-]{{0,62}}$)"
        )
    return cleaned


def _first_env(env: Mapping[str, str], names: tuple) -> Optional[str]:
    for name in names:
        value = env.get(name)
        if value:
            return value
    return None


def _http_get_json(url: str, token: str, timeout: float) -> dict:
    request = urllib.request.Request(url, headers={"X-Vault-Token": token})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_openbao_salt(
    env: Optional[Mapping[str, str]] = None,
    fetch: Callable[[str, str, float], dict] = _http_get_json,
) -> Optional[str]:
    """Return the salt from OpenBao, or None if it is unset, unreachable or empty."""
    env = os.environ if env is None else env
    addr = _first_env(env, _ADDR_VARS)
    token = _first_env(env, _TOKEN_VARS)
    if not addr or not token:
        return None
    url = addr.rstrip("/") + BAO_KV_PATH
    try:
        payload = fetch(url, token, BAO_TIMEOUT_SECONDS)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(f"derive_tenant_hash: OpenBao salt lookup failed ({exc}); "
              "falling back to SIGNAL_LOOM_EAP_SALT", file=sys.stderr)
        return None
    data = payload.get("data") if isinstance(payload, dict) else None
    inner = data.get("data") if isinstance(data, dict) else None
    salt = inner.get("salt") if isinstance(inner, dict) else None
    if isinstance(salt, str) and salt:
        return salt
    print("derive_tenant_hash: OpenBao returned no salt field; "
          "falling back to SIGNAL_LOOM_EAP_SALT", file=sys.stderr)
    return None


def resolve_salt(
    env: Optional[Mapping[str, str]] = None,
    fetch: Callable[[str, str, float], dict] = _http_get_json,
) -> str:
    env = os.environ if env is None else env
    salt = fetch_openbao_salt(env, fetch)
    if salt:
        return salt
    salt = env.get("SIGNAL_LOOM_EAP_SALT")
    if salt:
        return salt
    raise SaltUnavailableError(
        "EAP salt unavailable: provision secret/signalloom/eap in OpenBao "
        "or set SIGNAL_LOOM_EAP_SALT"
    )


def derive_tenant_hash(tenant_name: str, salt: Optional[str] = None) -> str:
    """Return the canonical 8-char lowercase hex tenant hash."""
    tenant = normalize_tenant(tenant_name)
    if salt is None:
        salt = resolve_salt()
    if not isinstance(salt, str) or not salt:
        raise SaltUnavailableError("EAP salt cannot be empty")
    digest = hashlib.sha256(f"{salt}:{tenant}".encode("utf-8")).hexdigest()[:8]
    if not _HASH_RE.match(digest):
        raise TenantHashError(f"derived hash '{digest}' is not 8 lowercase hex chars")
    return digest


def self_test() -> int:
    """Known-answer test. The pilot salt is an input to the vector, not a fallback."""
    checks = []
    got = derive_tenant_hash(CANONICAL_TENANT, salt=PILOT_SALT)
    checks.append((f"kusari -> {CANONICAL_HASH}", got == CANONICAL_HASH, got))
    checks.append(("kusari is not the unsalted digest", got != UNSALTED_KUSARI, got))
    try:
        derive_tenant_hash("kurasi", salt=PILOT_SALT)
        checks.append(("kurasi fails closed", False, "accepted"))
    except RetiredTenantError:
        checks.append(("kurasi fails closed", True, "rejected"))
    ok = True
    for name, passed, detail in checks:
        print(f"{'ok' if passed else 'FAIL'}: {name} ({detail})")
        ok = ok and passed
    return 0 if ok else 1


def main(argv: list) -> int:
    args = list(argv)
    quiet = False
    if args and args[0] in ("-q", "--quiet"):
        quiet = True
        args = args[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if not args:
        if quiet:
            print("usage: derive_tenant_hash.py [--quiet] <tenant_name>", file=sys.stderr)
            return 2
        return self_test()
    if len(args) != 1:
        print("usage: derive_tenant_hash.py [--quiet] <tenant_name>", file=sys.stderr)
        return 2
    tenant = args[0]
    try:
        digest = derive_tenant_hash(tenant)
    except (TenantHashError, SaltUnavailableError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if quiet:
        print(digest)
    else:
        print(f"Tenant: {normalize_tenant(tenant)} -> Hash: {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
