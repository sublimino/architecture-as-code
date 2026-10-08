"""Contract and authorization test suite for Signal Loom Feature Flags API and route gating.

Tests:
1. GET /api/v1/features schema, tenant scoping, and defaults.
2. Strict multi-tenant isolation and 403 prevention of cross-tenant query for non-superadmins.
3. Superadmin cross-tenant flag querying via ?tenant_id= parameter.
4. require_feature route gating: 404 on disabled/absent features, 200 on enabled features.
5. Superadmin override on feature-gated routes (?superadmin_override=true).
6. Performance latency benchmark (< 5ms cached evaluation).
7. Cache invalidation on flag mutations.
8. OpenAPI documentation exposure.
"""
from __future__ import annotations

import time
from typing import Annotated
from unittest.mock import Mock

import pytest
from api.features import install_features_api
from api_compat import (
    Principal,
    authenticated_principal,
    install_api_exception_handlers,
)
from conftest import (
    EAP_ALICE,
    EAP_BOB,
    EAP_OPERATOR,
    EAP_TENANT_A,
    EAP_TENANT_B,
    EAPClient,
)
from fastapi import APIRouter, Depends, FastAPI, HTTPException
from fastapi.testclient import TestClient
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    FeatureFlagDetail,
    FeatureFlagRepository,
    FeaturesResponse,
    invalidate_flag_cache,
    is_feature_enabled,
    require_feature,
)
from main import app as main_app
from test_feature_flags import FakePool

EAP_AUTHENTICATED = True


@pytest.fixture(autouse=True)
def _reset_flag_cache():
    """Ensure in-memory flag cache is clean for every test."""
    invalidate_flag_cache()
    yield
    invalidate_flag_cache()


@pytest.fixture
def fake_db_pool() -> FakePool:
    return FakePool()


# ===========================================================================
# 1. Contract & Authentication Tests for GET /api/v1/features
# ===========================================================================


def test_get_features_unauthenticated_returns_401() -> None:
    """Anonymous requests without Authorization header must be rejected with 401."""
    client = TestClient(main_app)
    resp = client.get("/api/v1/features")
    assert resp.status_code == 401
    payload = resp.json()
    assert payload["error"]["code"] in ("authentication_required", "invalid_token")


def test_get_features_invalid_token_returns_401() -> None:
    """Requests with malformed Bearer tokens must be rejected with 401."""
    client = TestClient(main_app)
    resp = client.get("/api/v1/features", headers={"Authorization": "Bearer invalid.token.payload"})
    assert resp.status_code == 401
    payload = resp.json()
    assert payload["error"]["code"] == "invalid_token"


def test_get_features_default_flags_for_authenticated_tenant() -> None:
    """Authenticated tenant with no DB overrides receives default system flags."""
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.get("/api/v1/features")
    assert resp.status_code == 200
    data = resp.json()

    assert data["tenant_id"] == EAP_TENANT_A
    assert isinstance(data["flags"], dict)
    assert isinstance(data["details"], dict)

    # Validate core defaults
    for key, expected_enabled in DEFAULT_SYSTEM_FLAGS.items():
        assert data["flags"][key] == expected_enabled
        assert key in data["details"]
        detail = data["details"][key]
        assert detail["enabled"] == expected_enabled
        assert isinstance(detail["config"], dict)


def test_get_features_with_database_overrides(fake_db_pool: FakePool, monkeypatch: pytest.MonkeyPatch) -> None:
    """Tenant-specific overrides in PostgreSQL take precedence over system defaults."""
    main_app.state.pool = fake_db_pool

    # Seed custom flags for Tenant A
    import asyncio
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="demos_fleet",
            enabled=True,
            config_json={"cluster_limit": 5, "tier": "beta"},
        )
    )
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="audit",
            enabled=False,
        )
    )

    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.get("/api/v1/features")
    assert resp.status_code == 200
    data = resp.json()

    assert data["tenant_id"] == EAP_TENANT_A
    # Overridden values
    assert data["flags"]["demos_fleet"] is True
    assert data["details"]["demos_fleet"]["enabled"] is True
    assert data["details"]["demos_fleet"]["config"] == {"cluster_limit": 5, "tier": "beta"}

    assert data["flags"]["audit"] is False
    assert data["details"]["audit"]["enabled"] is False

    # Default fallback preserved for unmodified keys
    assert data["flags"]["core_governance"] is True


# ===========================================================================
# 2. Multi-Tenant Isolation & Authorization Matrix
# ===========================================================================


def test_tenant_isolation_on_features_endpoint(fake_db_pool: FakePool) -> None:
    """Flags configured for Tenant A never bleed into Tenant B's feature dictionary."""
    main_app.state.pool = fake_db_pool

    import asyncio
    # Tenant A has demos_fleet enabled
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="demos_fleet",
            enabled=True,
            config_json={"tenant_a_secret": "alpha"},
        )
    )
    # Tenant B has supercred enabled, demos_fleet disabled
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_B,
            flag_key="supercred",
            enabled=True,
            config_json={"tenant_b_secret": "beta"},
        )
    )

    client_a = EAPClient(main_app, subject=EAP_ALICE)
    resp_a = client_a.get("/api/v1/features")
    assert resp_a.status_code == 200
    data_a = resp_a.json()
    assert data_a["tenant_id"] == EAP_TENANT_A
    assert data_a["flags"]["demos_fleet"] is True
    assert data_a["flags"]["supercred"] is False
    assert "tenant_b_secret" not in str(data_a)

    client_b = EAPClient(main_app, subject=EAP_BOB)
    resp_b = client_b.get("/api/v1/features")
    assert resp_b.status_code == 200
    data_b = resp_b.json()
    assert data_b["tenant_id"] == EAP_TENANT_B
    assert data_b["flags"]["demos_fleet"] is False
    assert data_b["flags"]["supercred"] is True
    assert "tenant_a_secret" not in str(data_b)


def test_cross_tenant_query_rejected_for_non_superadmin() -> None:
    """Standard tenant principals cannot query flags of other tenants via query param."""
    client = EAPClient(main_app, subject=EAP_ALICE)
    resp = client.get(f"/api/v1/features?tenant_id={EAP_TENANT_B}")
    assert resp.status_code == 403
    payload = resp.json()
    assert payload["error"]["code"] == "cross_tenant_forbidden"


def test_cross_tenant_query_permitted_for_superadmin(fake_db_pool: FakePool) -> None:
    """Superadmin principals may inspect feature flags for any tenant via tenant_id query param."""
    main_app.state.pool = fake_db_pool

    import asyncio
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_B,
            flag_key="demos_fleet",
            enabled=True,
            config_json={"custom": "val_b"},
        )
    )

    client = EAPClient(main_app, subject=EAP_OPERATOR)
    resp = client.get(f"/api/v1/features?tenant_id={EAP_TENANT_B}")
    assert resp.status_code == 200
    data = resp.json()
    assert data["tenant_id"] == EAP_TENANT_B
    assert data["flags"]["demos_fleet"] is True
    assert data["details"]["demos_fleet"]["config"] == {"custom": "val_b"}


# ===========================================================================
# 3. Server-Side Route Gating with require_feature(flag_key)
# ===========================================================================


def _build_test_gated_app(pool: FakePool) -> FastAPI:
    """Create a lightweight test FastAPI application with gated routes."""
    test_app = FastAPI()
    test_app.state.pool = pool
    install_api_exception_handlers(test_app)
    install_features_api(test_app)

    test_router = APIRouter()

    @test_router.get("/gated/demos-fleet", dependencies=[Depends(require_feature("demos_fleet"))])
    async def gated_demos_fleet(
        principal: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, str]:
        return {"status": "ok", "tenant": principal.tenant}

    @test_router.get("/gated/core-gov", dependencies=[Depends(require_feature("core_governance"))])
    async def gated_core_gov(
        principal: Annotated[Principal, Depends(authenticated_principal)],
    ) -> dict[str, str]:
        return {"status": "ok", "tenant": principal.tenant}

    @test_router.get("/gated/custom-gated")
    async def gated_custom(
        _gate: bool = Depends(require_feature("custom_feature")),
    ) -> dict[str, str]:
        return {"status": "ok", "feature": "custom"}

    test_app.include_router(test_router)
    return test_app


def test_disabled_feature_404(fake_db_pool: FakePool) -> None:
    """Route gated with disabled feature flag returns 404 Not Found to prevent information leak."""
    test_app = _build_test_gated_app(fake_db_pool)
    client = EAPClient(test_app, subject=EAP_ALICE)

    # demos_fleet is disabled by default
    resp = client.get("/gated/demos-fleet")
    assert resp.status_code == 404
    payload = resp.json()
    assert payload.get("error", {}).get("code") == "not_found" or payload.get("detail") == "Feature not found or disabled"


def test_absent_feature_404(fake_db_pool: FakePool) -> None:
    """Route gated with unconfigured/absent feature flag returns 404 Not Found."""
    test_app = _build_test_gated_app(fake_db_pool)
    client = EAPClient(test_app, subject=EAP_ALICE)

    resp = client.get("/gated/custom-gated")
    assert resp.status_code == 404
    payload = resp.json()
    assert payload.get("error", {}).get("code") == "not_found" or payload.get("detail") == "Feature not found or disabled"


@pytest.mark.asyncio
async def test_require_feature_direct_callable_raises_404_with_detail(fake_db_pool: FakePool) -> None:
    """Direct invocation of require_feature dependency callable raises HTTPException with exact 404 detail."""
    mock_request = Mock()
    mock_request.app.state.pool = fake_db_pool

    gate = require_feature("disabled_flag")
    alice_principal = Principal(tenant=EAP_TENANT_A, subject=EAP_ALICE, email=None)

    with pytest.raises(HTTPException) as exc_info:
        await gate(mock_request, principal=alice_principal, superadmin_override=False)

    assert exc_info.value.status_code == 404
    assert exc_info.value.detail == "Feature not found or disabled"


def test_enabled_feature_200(fake_db_pool: FakePool) -> None:
    """Route gated with enabled feature flag returns 200 OK."""
    test_app = _build_test_gated_app(fake_db_pool)

    import asyncio
    # Enable demos_fleet for Tenant A
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="demos_fleet",
            enabled=True,
        )
    )

    client = EAPClient(test_app, subject=EAP_ALICE)
    resp = client.get("/gated/demos-fleet")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "tenant": EAP_TENANT_A}


def test_default_enabled_feature_200(fake_db_pool: FakePool) -> None:
    """Route gated with core_governance (default enabled) returns 200 OK without DB row."""
    test_app = _build_test_gated_app(fake_db_pool)
    client = EAPClient(test_app, subject=EAP_ALICE)

    resp = client.get("/gated/core-gov")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_superadmin_override_on_disabled_feature(fake_db_pool: FakePool) -> None:
    """Superadmin with ?superadmin_override=true bypasses feature gate on disabled routes."""
    test_app = _build_test_gated_app(fake_db_pool)

    # 1. Non-superadmin with superadmin_override is STILL rejected with 404
    client_alice = EAPClient(test_app, subject=EAP_ALICE)
    resp_alice = client_alice.get("/gated/demos-fleet?superadmin_override=true")
    assert resp_alice.status_code == 404

    # 2. Superadmin WITHOUT superadmin_override gets 404 if flag is disabled
    client_op = EAPClient(test_app, subject=EAP_OPERATOR)
    resp_op_no_override = client_op.get("/gated/demos-fleet")
    assert resp_op_no_override.status_code == 404

    # 3. Superadmin WITH superadmin_override=true gets 200 OK
    resp_op_override = client_op.get("/gated/demos-fleet?superadmin_override=true")
    assert resp_op_override.status_code == 200
    assert resp_op_override.json()["status"] == "ok"


def test_unauthenticated_request_on_gated_route(fake_db_pool: FakePool) -> None:
    """Unauthenticated request to feature-gated route returns 401."""
    test_app = _build_test_gated_app(fake_db_pool)
    client = TestClient(test_app)

    resp = client.get("/gated/core-gov")
    assert resp.status_code == 401


# ===========================================================================
# 4. Latency Benchmark & Caching Validation
# ===========================================================================


def test_cached_evaluation_latency_under_5ms(fake_db_pool: FakePool) -> None:
    """Verify that cached feature flag evaluations execute with under 5ms overhead."""
    import asyncio

    # Seed flag
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="demos_fleet",
            enabled=True,
        )
    )

    # Warm cache
    asyncio.run(is_feature_enabled(fake_db_pool, EAP_TENANT_A, "demos_fleet"))

    # Benchmark 200 cached evaluations
    start_time = time.perf_counter()
    iterations = 200
    for _ in range(iterations):
        res = asyncio.run(is_feature_enabled(fake_db_pool, EAP_TENANT_A, "demos_fleet"))
        assert res is True
    elapsed = time.perf_counter() - start_time
    avg_latency_ms = (elapsed / iterations) * 1000.0

    # Latency overhead per call should be well under 5.0ms (typically < 0.1ms)
    assert avg_latency_ms < 5.0, f"Average latency was {avg_latency_ms:.3f}ms (target < 5.0ms)"


def test_cache_invalidation_on_flag_update(fake_db_pool: FakePool) -> None:
    """Mutating a flag invalidates the cache immediately."""
    import asyncio

    # Initially enabled
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="supercred",
            enabled=True,
        )
    )
    assert asyncio.run(is_feature_enabled(fake_db_pool, EAP_TENANT_A, "supercred")) is True

    # Mutate to disabled
    asyncio.run(
        FeatureFlagRepository.set_feature_flag(
            fake_db_pool,
            tenant_id=EAP_TENANT_A,
            flag_key="supercred",
            enabled=False,
        )
    )

    # Next evaluation must observe change immediately without waiting for TTL
    assert asyncio.run(is_feature_enabled(fake_db_pool, EAP_TENANT_A, "supercred")) is False


# ===========================================================================
# 5. Pydantic Response Model Validation
# ===========================================================================


def test_pydantic_features_response_model() -> None:
    """Validate FeaturesResponse model parsing, serialization, and round-tripping."""
    detail = FeatureFlagDetail(enabled=True, config={"max_users": 100})
    response_model = FeaturesResponse(
        tenant_id="tenant-acme",
        flags={"core_governance": True, "supercred": False},
        details={"core_governance": detail},
    )

    dump = response_model.model_dump()
    assert dump["tenant_id"] == "tenant-acme"
    assert dump["flags"]["core_governance"] is True
    assert dump["flags"]["supercred"] is False
    assert dump["details"]["core_governance"]["enabled"] is True
    assert dump["details"]["core_governance"]["config"] == {"max_users": 100}

    # Deserialization
    reconstructed = FeaturesResponse.model_validate(dump)
    assert reconstructed.tenant_id == response_model.tenant_id
    assert reconstructed.flags == response_model.flags
    assert reconstructed.details["core_governance"].config == {"max_users": 100}


def test_openapi_schema_exposes_features_route() -> None:
    """Verify that /api/v1/features is registered in the OpenAPI schema."""
    schema = main_app.openapi()
    assert "/api/v1/features" in schema["paths"]
    assert "get" in schema["paths"]["/api/v1/features"]
    get_op = schema["paths"]["/api/v1/features"]["get"]
    assert "features" in get_op.get("tags", [])
    assert "200" in get_op["responses"]
