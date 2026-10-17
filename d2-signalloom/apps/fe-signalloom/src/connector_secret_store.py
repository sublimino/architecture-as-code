"""Connector credentials in OpenBao KV v2 (SA-TODO-003).

A tenant's connector credentials (an Anthropic API key, a GitHub token) live
in OpenBao at ``kv/data/signalloom/tenants/<tenant>/connectors/<connector>``.
``public.tenant_connectors`` keeps only the reference: ``credentials_ref``
(the path) and ``credentials_version`` (the KV v2 version written). The old
``credentials_ciphertext`` column is no longer written; a row that still has
one and no reference was never migrated and answers 503 until
``scripts/migrate-connector-creds-to-openbao.py`` moves it. There is no
fallback to it, and no plaintext fallback of any kind.

Authentication: the fe-signalloom pod logs in as OpenBao role
``signalloom-fe-signalloom`` from its SPIFFE identity through a bao agent
sidecar (the fleet-manager pattern). The agent writes a short-lived token to
``BAO_TOKEN_FILE``; it is read again on every request because the agent
replaces it. ``BAO_ADDR`` names the server.

Tenant isolation: the portal is one OpenBao identity for every tenant, so a
per-tenant OpenBao policy is not possible (it would need one SPIFFE identity
per tenant). The policy grants ``signalloom/tenants/+/connectors/+``; the
tenant boundary is enforced here and in the router: every path is built from
the authenticated principal's tenant, ids are restricted to a safe alphabet,
and a stored reference must equal the path for the row's own tenant and
connector before it is read.

Every failure -- no configuration, no token, OpenBao unreachable, sealed,
denied, or the secret missing -- raises :class:`CredentialStoreUnavailable`,
which the router turns into 503 ``credential_store_unavailable``. Error text
never carries a token or a credential value.

Test seam: :func:`set_store_for_testing` replaces the store
(``tests/connector_secret_store_fake.py``).
"""
from __future__ import annotations

import os
import re
from typing import Any, Optional, Protocol

import httpx

MOUNT_ENV = "CONNECTOR_KV_MOUNT"
DEFAULT_MOUNT = "kv"
PATH_PREFIX = "signalloom/tenants"
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class CredentialStoreUnavailable(Exception):
    """Credentials can be neither stored nor read; the caller answers 503."""


def _check_id(kind: str, value: str) -> str:
    if not isinstance(value, str) or not _SAFE_ID.fullmatch(value) or ".." in value:
        raise CredentialStoreUnavailable(f"{kind} id is not a safe path segment")
    return value


def tenant_path(tenant_id: str, connector_id: str) -> str:
    """The KV path (without mount or ``data/``) for this tenant's connector."""
    return f"{PATH_PREFIX}/{_check_id('tenant', tenant_id)}/connectors/{_check_id('connector', connector_id)}"


def check_ref(tenant_id: str, connector_id: str, ref: str) -> None:
    """Refuse a stored reference that is not this tenant's own connector path."""
    if ref != tenant_path(tenant_id, connector_id):
        raise CredentialStoreUnavailable("the stored credential reference does not belong to this tenant and connector")


class SecretStore(Protocol):
    def require(self) -> None: ...
    def put(self, tenant_id: str, connector_id: str, credentials: dict[str, str]) -> tuple[str, int]: ...
    def get(self, tenant_id: str, connector_id: str, ref: str, version: Any = None) -> dict[str, str]: ...
    def delete(self, tenant_id: str, connector_id: str) -> None: ...


class OpenBaoKvStore:
    """OpenBao KV v2 over HTTP, token from a file the bao agent keeps fresh."""

    def __init__(self, addr: Optional[str] = None, token_file: Optional[str] = None,
                 mount: Optional[str] = None, timeout: float = 5.0) -> None:
        self.addr = (addr if addr is not None else os.environ.get("BAO_ADDR", "")).rstrip("/")
        self.token_file = token_file if token_file is not None else os.environ.get("BAO_TOKEN_FILE", "")
        self.mount = mount or os.environ.get(MOUNT_ENV, DEFAULT_MOUNT)
        self.timeout = timeout

    def _token(self) -> str:
        if not self.addr:
            raise CredentialStoreUnavailable("BAO_ADDR is not set")
        if not self.token_file:
            raise CredentialStoreUnavailable("BAO_TOKEN_FILE is not set")
        try:
            with open(self.token_file, encoding="utf-8") as fh:
                token = fh.read().strip()
        except OSError as exc:
            raise CredentialStoreUnavailable(f"the OpenBao token file cannot be read ({type(exc).__name__})") from None
        if not token:
            raise CredentialStoreUnavailable("the OpenBao token file is empty")
        return token

    def _request(self, method: str, suffix: str, **kwargs: Any) -> httpx.Response:
        token = self._token()
        try:
            with httpx.Client(base_url=self.addr, timeout=self.timeout,
                              headers={"X-Vault-Token": token}) as client:
                return client.request(method, f"/v1/{self.mount}/{suffix}", **kwargs)
        except httpx.HTTPError as exc:
            raise CredentialStoreUnavailable(f"OpenBao is unreachable ({type(exc).__name__})") from None

    @staticmethod
    def _fail(what: str, response: httpx.Response) -> CredentialStoreUnavailable:
        # Status only: OpenBao error bodies can echo request data.
        return CredentialStoreUnavailable(f"OpenBao refused to {what}: HTTP {response.status_code}")

    def require(self) -> None:
        self._token()

    def put(self, tenant_id: str, connector_id: str, credentials: dict[str, str]) -> tuple[str, int]:
        path = tenant_path(tenant_id, connector_id)
        response = self._request("POST", f"data/{path}", json={"data": dict(credentials)})
        if response.status_code not in (200, 204):
            raise self._fail("store the credentials", response)
        try:
            version = int(response.json()["data"]["version"])
        except (ValueError, KeyError, TypeError):
            raise CredentialStoreUnavailable("OpenBao did not return a KV version") from None
        return path, version

    def get(self, tenant_id: str, connector_id: str, ref: str, version: Any = None) -> dict[str, str]:
        check_ref(tenant_id, connector_id, ref)
        params = {"version": str(int(version))} if version else None
        response = self._request("GET", f"data/{ref}", params=params)
        if response.status_code == 404:
            raise CredentialStoreUnavailable(f"no secret at the stored reference for {connector_id}")
        if response.status_code != 200:
            raise self._fail("read the credentials", response)
        try:
            data = response.json()["data"]["data"]
        except (ValueError, KeyError, TypeError):
            data = None
        if not isinstance(data, dict):
            raise CredentialStoreUnavailable(f"no secret at the stored reference for {connector_id}")
        return {str(k): str(v) for k, v in data.items()}

    def delete(self, tenant_id: str, connector_id: str) -> None:
        path = tenant_path(tenant_id, connector_id)
        response = self._request("DELETE", f"metadata/{path}")
        if response.status_code not in (200, 204, 404):
            raise self._fail("delete the credentials", response)


_STORE: Optional[SecretStore] = None


def get_store() -> SecretStore:
    return _STORE if _STORE is not None else OpenBaoKvStore()


def set_store_for_testing(store: Optional[SecretStore]) -> None:
    global _STORE
    _STORE = store


def open_row(tenant_id: str, row: Any, store: Optional[SecretStore] = None) -> dict[str, str]:
    """The credentials a ``tenant_connectors`` row refers to, or {} when it has none.

    A row with only the old sealed ciphertext was not migrated: it is refused,
    never decrypted here.
    """
    def field(name: str) -> Any:
        try:
            return row[name]
        except (KeyError, IndexError):
            return None

    ref = field("credentials_ref")
    if ref:
        return (store or get_store()).get(tenant_id, row["connector_id"], ref, field("credentials_version"))
    if field("credentials_ciphertext"):
        raise CredentialStoreUnavailable(
            "these credentials were not migrated to OpenBao (scripts/migrate-connector-creds-to-openbao.py)")
    return {}
