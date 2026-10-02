"""The credential fe-signalloom presents to signal-ingest.

signal-ingest authenticates every route with named static keys (Andy, 2026-10-02: no SPIRE for
callers). fe-signalloom holds one, ``fe-signalloom-gateway``, carrying ``tenant:act-for``: every
request names the verified dashboard user's tenant in ``X-SignalLoom-Acting-Tenant`` and
signal-ingest scopes reads and writes to it. Without this the proxies forwarded every tenant's
data to every user: they resolved the caller's tenant and never used it.

Rules:
  * The tenant comes only from the validated ``Principal`` (API_SUBJECT_TENANTS), never from a
    header, query or body the caller writes.
  * A superadmin (``superadmin.is_superadmin``) reads as ``*`` — all tenants. signal-ingest
    honours ``*`` only for a key that also holds ``tenant:cross-read`` and logs it with the
    subject sent in ``X-SignalLoom-Acting-Subject``. Writes always act for the user's own tenant.
  * Nobody else can produce ``*``: a tenant mapping that is not a plain tenant id is refused.
  * The key is read from its mounted Secret file on every call (a rotation needs no restart). A
    missing or unusable key is a 503; a request is never sent without it. The key is never logged.
"""
from __future__ import annotations

import os
import re

from api_compat import APIError, Principal
from superadmin import is_superadmin

KEY_FILE_ENV = "SIGNAL_INGEST_KEY_FILE"
DEFAULT_KEY_FILE = "/etc/fe-signalloom/ingest-key/token"
ACTING_TENANT_HEADER = "X-SignalLoom-Acting-Tenant"
ACTING_SUBJECT_HEADER = "X-SignalLoom-Acting-Subject"
ALL_TENANTS = "*"

# signal-ingest's own acting-tenant shape (api.actingTenantPattern): ASCII, no leading underscore.
_TENANT_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,62}")
_MIN_KEY_BYTES = 32


def _gateway_key() -> str:
    path = os.environ.get(KEY_FILE_ENV, DEFAULT_KEY_FILE)
    try:
        with open(path, encoding="utf-8") as fh:
            key = fh.read()
    except OSError:
        raise APIError(503, "ingest_credential_unavailable", "signal-ingest credential is not mounted") from None
    key = key[:-1] if key.endswith("\n") else key
    if len(key) < _MIN_KEY_BYTES or any(c.isspace() for c in key):
        raise APIError(503, "ingest_credential_unavailable", "signal-ingest credential is unusable")
    return key


def acting_tenant(principal: Principal, *, write: bool = False) -> str:
    """The tenant a request acts for: ``*`` for a superadmin read, else the user's own tenant."""
    if not write and is_superadmin(principal):
        return ALL_TENANTS
    if not _TENANT_ID.fullmatch(principal.tenant or ""):
        raise APIError(403, "tenant_forbidden", "Subject has no usable tenant")
    return principal.tenant


def ingest_headers(principal: Principal, *, write: bool = False) -> dict[str, str]:
    """Headers for one signal-ingest request on behalf of ``principal``."""
    acting = acting_tenant(principal, write=write)
    return {
        "Authorization": f"Bearer {_gateway_key()}",
        ACTING_TENANT_HEADER: acting,
        ACTING_SUBJECT_HEADER: principal.subject,
    }


def ingest_headers_for_tenant(tenant: str | None, subject: str) -> dict[str, str]:
    """Headers for a signal-ingest write made outside a request handler (claim sync) on behalf of
    ``tenant``. Never ``*``: a background write always names one real tenant."""
    if not _TENANT_ID.fullmatch(tenant or ""):
        raise APIError(403, "tenant_forbidden", "No usable tenant for a signal-ingest write")
    return {
        "Authorization": f"Bearer {_gateway_key()}",
        ACTING_TENANT_HEADER: tenant,
        ACTING_SUBJECT_HEADER: subject,
    }
