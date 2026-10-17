"""An in-memory stand-in for ``connector_secret_store.OpenBaoKvStore``.

It enforces the same contract as the real store: values live under
``signalloom/tenants/<tenant>/connectors/<connector>``, each write bumps a
KV v2 version, a read must name the tenant's own path, ``delete`` removes all
versions, and ``down=True`` makes every call raise
:class:`connector_secret_store.CredentialStoreUnavailable` -- the state of an
unreachable OpenBao.
"""
from __future__ import annotations

from typing import Any

import connector_secret_store as css


class FakeKvStore:
    def __init__(self) -> None:
        self.down = False
        # path -> list of versions (index 0 is version 1)
        self.secrets: dict[str, list[dict[str, str]]] = {}
        self.deleted: list[str] = []
        self.calls: list[tuple[str, str]] = []

    def _check(self) -> None:
        if self.down:
            raise css.CredentialStoreUnavailable("OpenBao is unreachable (fake)")

    def require(self) -> None:
        self._check()

    def put(self, tenant_id: str, connector_id: str, credentials: dict[str, str]) -> tuple[str, int]:
        self._check()
        path = css.tenant_path(tenant_id, connector_id)
        self.calls.append(("put", path))
        self.secrets.setdefault(path, []).append(dict(credentials))
        return path, len(self.secrets[path])

    def get(self, tenant_id: str, connector_id: str, ref: str, version: Any = None) -> dict[str, str]:
        self._check()
        css.check_ref(tenant_id, connector_id, ref)
        self.calls.append(("get", ref))
        versions = self.secrets.get(ref)
        if not versions:
            raise css.CredentialStoreUnavailable(f"no secret at {ref}")
        index = (int(version) if version else len(versions)) - 1
        return dict(versions[index])

    def delete(self, tenant_id: str, connector_id: str) -> None:
        self._check()
        path = css.tenant_path(tenant_id, connector_id)
        self.calls.append(("delete", path))
        self.secrets.pop(path, None)
        self.deleted.append(path)

    def values(self) -> list[str]:
        return [v for versions in self.secrets.values() for creds in versions for v in creds.values()]
