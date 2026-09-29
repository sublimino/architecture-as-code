"""Tests for Policy Engine reverse proxy and tenant scoping in fe-signalloom."""
import json
import pytest
from httpx import AsyncClient, ASGITransport
import respx
import httpx

from main import app
from config import settings
from conftest import eap_bearer, EAP_ALICE, EAP_TENANT_A, EAP_BOB, EAP_TENANT_B

EAP_AUTHENTICATED = True


@pytest.mark.asyncio
async def test_policy_engine_proxy_list_policies():
    """Test GET /api/v1/policies proxies to policy engine injecting X-Tenant-ID."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{policy_engine_url}/api/v1/policies").mock(
            return_value=httpx.Response(
                200,
                json=[
                    {
                        "framework_id": "eu-ai-act",
                        "active_version": "v1.0.0",
                        "latest_version": "v1.0.0",
                        "version_history": [
                            {"version": "v1.0.0", "author": "system", "rule_count": 4}
                        ],
                    }
                ],
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/policies", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 200
            data = resp.json()
            assert len(data) == 1
            assert data[0]["framework_id"] == "eu-ai-act"
            assert route.called
            last_req = route.calls.last.request
            assert "X-Tenant-ID" in last_req.headers
            assert last_req.headers["X-Tenant-ID"] == EAP_TENANT_A


@pytest.mark.asyncio
async def test_policy_engine_proxy_evaluate():
    """Test POST /api/v1/policies/evaluate proxies evaluation context with tenant scoping."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.post(f"{policy_engine_url}/api/v1/policies/evaluate").mock(
            return_value=httpx.Response(
                200,
                json={
                    "compliant": True,
                    "tenant_id": EAP_TENANT_A,
                    "framework_id": "eu-ai-act",
                    "policy_version": "v1.0.0",
                    "total_rules": 2,
                    "passed_rules": 2,
                    "failed_rules": 0,
                    "total_exposure_gbp": 0.0,
                    "results": [],
                },
            )
        )

        eval_payload = {
            "framework_id": "eu-ai-act",
            "agent": {
                "id": "agent-1",
                "model": "claude-3-5-sonnet",
            },
        }

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post("/api/v1/policies/evaluate", json=eval_payload, headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 200
            data = resp.json()
            assert data["compliant"] is True
            assert route.called
            last_req = route.calls.last.request
            assert last_req.headers["X-Tenant-ID"] == EAP_TENANT_A


@pytest.mark.asyncio
async def test_policy_engine_proxy_bundle_creation_and_rollback():
    """Test POST /api/v1/policies/bundles and POST /api/v1/policies/rollback."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        bundle_route = respx_mock.post(f"{policy_engine_url}/api/v1/policies/bundles").mock(
            return_value=httpx.Response(
                201,
                json={
                    "id": "eu-ai-act-v1.1.0",
                    "framework_id": "eu-ai-act",
                    "version": "v1.1.0",
                    "author": EAP_ALICE,
                    "rules": [{"id": "r1", "name": "Check", "cel_expression": "true"}],
                },
            )
        )
        rollback_route = respx_mock.post(f"{policy_engine_url}/api/v1/policies/rollback").mock(
            return_value=httpx.Response(
                200,
                json={
                    "id": "eu-ai-act-v1.0.0",
                    "framework_id": "eu-ai-act",
                    "version": "v1.0.0",
                    "author": "system",
                },
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            # 1. Create bundle
            bundle_payload = {
                "framework_id": "eu-ai-act",
                "version": "v1.1.0",
                "rules": [{"id": "r1", "name": "Check", "cel_expression": "true"}],
            }
            resp_bundle = await client.post("/api/v1/policies/bundles", json=bundle_payload, headers=eap_bearer(EAP_ALICE))
            assert resp_bundle.status_code == 201
            assert resp_bundle.json()["version"] == "v1.1.0"
            assert bundle_route.called

            # 2. Rollback bundle
            rb_payload = {
                "framework_id": "eu-ai-act",
                "target_version": "v1.0.0",
            }
            resp_rb = await client.post("/api/v1/policies/rollback", json=rb_payload, headers=eap_bearer(EAP_ALICE))
            assert resp_rb.status_code == 200
            assert resp_rb.json()["version"] == "v1.0.0"
            assert rollback_route.called


@pytest.mark.asyncio
async def test_forged_tenant_header_ignored():
    """Test client-supplied X-Tenant-ID header is stripped and overwritten with authenticated tenant."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{policy_engine_url}/api/v1/policies").mock(
            return_value=httpx.Response(200, json=[])
        )

        headers = dict(eap_bearer(EAP_ALICE))
        headers["X-Tenant-ID"] = "tenant-attacker-override"

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/policies", headers=headers)
            assert resp.status_code == 200
            last_req = route.calls.last.request
            assert last_req.headers["X-Tenant-ID"] == EAP_TENANT_A
            assert "tenant-attacker-override" not in last_req.headers["X-Tenant-ID"]
