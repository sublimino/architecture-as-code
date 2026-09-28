"""Tenant binding for the five EAP routers (EAPR-P2-1, decision 2026-09-23).

One home for the three things every EAP router needs and none may redefine:

* ``TENANT_KEY_RE`` — the only accepted shape of a customer hash.  Applied to
  every path, body and query parameter named ``customer_hash`` so a non-hex key
  is refused with 422 before any handler or store sees it (SLES B13).
* ``Tenant`` — the caller's tenant, taken from ``api_compat.authenticated_tenant``
  and nowhere else.  No handler reads an identity header; ``main.py`` strips
  them at ingress so a handler cannot regress by accident.
* ``GLOBAL_TENANT_OWNERSHIP`` — which tenant owns which customer hash.  The four
  EAP engines (tenant boundaries, environments, lifecycle, scenarios) are
  in-memory and keyed by hash, not by tenant; this map is the single binding
  between the principal and those keys.  A hash is claimed by the first tenant
  that creates something under it and stays theirs; another tenant addressing
  it gets 404 (reads and hash-addressed mutations, so existence is never
  leaked) or 403 (creates, where the card asks for it explicitly).

This module sits at the root of the EAP import graph: it imports ``api_compat``
and FastAPI only, so ``environment_routing`` (which the other four import) can
depend on it without a cycle.
"""
from __future__ import annotations

import re
import threading
from typing import Annotated, Dict, Set

from fastapi import Depends, HTTPException, Path, status

import api_compat

CUSTOMER_HASH_PATTERN = r"^[0-9a-f]{8}$"
TENANT_KEY_RE = re.compile(CUSTOMER_HASH_PATTERN)

#: The caller's tenant.  The one and only source of tenancy for EAP handlers.
Tenant = Annotated[str, Depends(api_compat.authenticated_tenant)]


def validate_customer_hash(
    customer_hash: str = Path(..., pattern=CUSTOMER_HASH_PATTERN, description="8-char lowercase hex tenant key"),
) -> str:
    """Path-parameter dependency: a customer hash is eight lowercase hex chars or it is 422."""
    return customer_hash


#: Use as the type of every ``customer_hash`` path parameter on an EAP route.
CustomerHash = Annotated[str, Depends(validate_customer_hash)]


class CustomerHashOwnedByAnotherTenant(Exception):
    """A tenant tried to create under a hash that another tenant already owns."""


class TenantOwnership:
    """Thread-safe ``customer_hash -> tenant`` map shared by the EAP engines."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._owner: Dict[str, str] = {}

    def claim(self, customer_hash: str, tenant: str) -> str:
        """Bind ``customer_hash`` to ``tenant``; idempotent for the owner, refused for anyone else."""
        h = customer_hash.lower()
        with self._lock:
            owner = self._owner.get(h)
            if owner is None:
                self._owner[h] = tenant
            elif owner != tenant:
                raise CustomerHashOwnedByAnotherTenant(h)
        return h

    def is_owned_by(self, customer_hash: str, tenant: str) -> bool:
        with self._lock:
            return self._owner.get(customer_hash.lower()) == tenant

    def hashes_for(self, tenant: str) -> Set[str]:
        with self._lock:
            return {h for h, owner in self._owner.items() if owner == tenant}

    def owner_of(self, customer_hash: str) -> str | None:
        with self._lock:
            return self._owner.get(customer_hash.lower())


GLOBAL_TENANT_OWNERSHIP = TenantOwnership()


def claim_or_403(customer_hash: str, tenant: str) -> str:
    """Creates: bind the hash to the caller, or 403 when it belongs to someone else."""
    try:
        return GLOBAL_TENANT_OWNERSHIP.claim(customer_hash, tenant)
    except CustomerHashOwnedByAnotherTenant as exc:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="customer_hash belongs to another tenant",
        ) from exc


def require_owned_or_404(customer_hash: str, tenant: str) -> str:
    """Reads and hash-addressed mutations: anything the caller does not own is not found."""
    h = customer_hash.lower()
    if not GLOBAL_TENANT_OWNERSHIP.is_owned_by(h, tenant):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="not found")
    return h


def owned_hashes(tenant: str) -> Set[str]:
    """The hashes a listing may show to ``tenant``."""
    return GLOBAL_TENANT_OWNERSHIP.hashes_for(tenant)
