"""Deterministic, local-only backend adapters used by the Signal Loom demo."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping
from urllib.parse import urlparse


LOCAL_PROXY_HOST = "fake-integration-proxy.inf-signalloom.svc.cluster.local"


def _require_local_url(value: str, name: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError(f"{name} must be an absolute local URL")
    if parsed.hostname not in {"postgresql", "redis", "minio", "openbao", LOCAL_PROXY_HOST}:
        raise ValueError(f"{name} must target an isolated local backend")
    return value.rstrip("/")


@dataclass(frozen=True)
class PlatformRecord:
    identifier: str
    name: str
    tenant_id: str = "tenant-demo"


@dataclass
class PostgresAdapter:
    records: dict[tuple[str, str], PlatformRecord]

    def get(self, tenant_id: str, identifier: str) -> PlatformRecord:
        try:
            return self.records[(tenant_id, identifier)]
        except KeyError as error:
            raise LookupError("platform record not found") from error


@dataclass
class RedisAdapter:
    values: dict[str, str] = field(default_factory=dict)

    def get(self, key: str) -> str:
        try:
            return self.values[key]
        except KeyError as error:
            raise LookupError("cache key not found") from error


@dataclass
class MinIOAdapter:
    objects: dict[str, bytes] = field(default_factory=dict)

    def read(self, key: str) -> bytes:
        try:
            return self.objects[key]
        except KeyError as error:
            raise LookupError("object not found") from error


@dataclass
class OpenBaoAdapter:
    secrets: dict[str, Mapping[str, str]] = field(default_factory=dict)

    def read(self, path: str) -> Mapping[str, str]:
        try:
            return self.secrets[path]
        except KeyError as error:
            raise LookupError("secret reference not found") from error


@dataclass(frozen=True)
class FakeIntegrationProxyAdapter:
    endpoint: str

    @classmethod
    def from_endpoint(cls, endpoint: str) -> "FakeIntegrationProxyAdapter":
        value = _require_local_url(endpoint, "fake integration proxy endpoint")
        if urlparse(value).hostname != LOCAL_PROXY_HOST:
            raise ValueError("fake integration proxy endpoint must be internal")
        return cls(value)

    def route(self, group: str) -> str:
        if group not in {"llm", "crm", "notification", "outbound-reporting"}:
            raise ValueError("unsupported fake integration group")
        return f"{self.endpoint}/{group}"


@dataclass(frozen=True)
class FakeServiceAdapter:
    def respond(self, operation: str) -> Mapping[str, str]:
        if operation != "connector-status":
            raise LookupError("fake service operation not found")
        return {"status": "ready", "source": "fake-service", "tenant_id": "tenant-demo"}


@dataclass
class LocalBackends:
    postgres: PostgresAdapter
    redis: RedisAdapter
    minio: MinIOAdapter
    openbao: OpenBaoAdapter
    proxy: FakeIntegrationProxyAdapter
    fake_service: FakeServiceAdapter


def seed_local_backends(proxy_endpoint: str = f"http://{LOCAL_PROXY_HOST}:8080") -> LocalBackends:
    """Create repeatable demo data; no adapter performs network I/O."""
    return LocalBackends(
        postgres=PostgresAdapter({("tenant-demo", "platform-demo"): PlatformRecord("platform-demo", "Demo Platform")}),
        redis=RedisAdapter({"tenant-demo:platform": "platform-demo"}),
        minio=MinIOAdapter({"reports/platform-demo.json": b'{"platform":"platform-demo"}'}),
        openbao=OpenBaoAdapter({"secret/signalloom/demo": {"token": "demo-token"}}),
        proxy=FakeIntegrationProxyAdapter.from_endpoint(proxy_endpoint),
        fake_service=FakeServiceAdapter(),
    )
