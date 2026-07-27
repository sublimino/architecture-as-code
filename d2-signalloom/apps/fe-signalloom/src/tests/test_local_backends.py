import pytest

from integrations.local_backends import FakeIntegrationProxyAdapter, seed_local_backends


def test_seeded_local_backend_adapters_expose_deterministic_integration_data():
    backends = seed_local_backends()

    assert backends.postgres.get("tenant-demo", "platform-demo").tenant_id == "tenant-demo"
    assert backends.redis.get("tenant-demo:platform") == "platform-demo"
    assert backends.minio.read("reports/platform-demo.json") == b'{"platform":"platform-demo"}'
    assert backends.openbao.read("secret/signalloom/demo") == {"token": "demo-token"}
    assert backends.proxy.route("crm").endswith("/crm")
    assert backends.fake_service.respond("connector-status")["source"] == "fake-service"


@pytest.mark.parametrize(
    "operation",
    [
        lambda backends: backends.postgres.get("tenant-demo", "absent"),
        lambda backends: backends.redis.get("absent"),
        lambda backends: backends.minio.read("absent"),
        lambda backends: backends.openbao.read("secret/absent"),
        lambda backends: backends.fake_service.respond("unknown"),
    ],
)
def test_missing_local_backend_data_fails_closed(operation):
    with pytest.raises(LookupError):
        operation(seed_local_backends())


@pytest.mark.parametrize(
    "endpoint",
    [
        "https://api.example.com",
        "http://fake-integration-proxy:8080",
        "not-a-url",
    ],
)
def test_proxy_rejects_external_or_ambiguous_targets(endpoint):
    with pytest.raises(ValueError):
        FakeIntegrationProxyAdapter.from_endpoint(endpoint)


def test_proxy_rejects_unknown_fake_service_group():
    with pytest.raises(ValueError, match="unsupported"):
        seed_local_backends().proxy.route("external")


def test_postgres_adapter_rejects_cross_tenant_record_access():
    with pytest.raises(LookupError):
        seed_local_backends().postgres.get("tenant-other", "platform-demo")
