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


@pytest.mark.asyncio
async def test_policy_engine_proxy_body_tenant_validation_and_whitespace():
    """Test body tenant validation rejects foreign tenants and tolerates whitespace padding."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.post(f"{policy_engine_url}/api/v1/policies/evaluate").mock(
            return_value=httpx.Response(200, json={"compliant": True})
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            # 1. Matching tenant with trailing whitespace should succeed
            eval_payload_ws = {
                "framework_id": "eu-ai-act",
                "tenant_id": f"  {EAP_TENANT_A}  ",
            }
            resp_ws = await client.post(
                "/api/v1/policies/evaluate",
                json=eval_payload_ws,
                headers=eap_bearer(EAP_ALICE),
            )
            assert resp_ws.status_code == 200
            assert route.called

            # 2. Foreign tenant should be rejected with 403 cross_tenant_forbidden
            eval_payload_foreign = {
                "framework_id": "eu-ai-act",
                "tenant_id": EAP_TENANT_B,
            }
            resp_foreign = await client.post(
                "/api/v1/policies/evaluate",
                json=eval_payload_foreign,
                headers=eap_bearer(EAP_ALICE),
            )
            assert resp_foreign.status_code == 403
            assert resp_foreign.json()["error"]["code"] == "cross_tenant_forbidden"


@pytest.mark.asyncio
async def test_policy_engine_proxy_handles_204_no_content():
    """Test proxy cleanly forwards 204 No Content without crashing on JSON deserialization."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{policy_engine_url}/api/v1/compliance/noop").mock(
            return_value=httpx.Response(
                204,
                content=b"",
                headers={"X-Tenant-ID": EAP_TENANT_A},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/compliance/noop", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 204
            assert resp.content == b""
            assert route.called
            assert resp.headers.get("x-tenant-id") == EAP_TENANT_A


@pytest.mark.asyncio
async def test_policy_engine_proxy_handles_empty_body_and_head():
    """Test proxy cleanly handles empty bodies and HEAD requests without 502 Bad Gateway errors."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{policy_engine_url}/api/v1/compliance/empty-check").mock(
            return_value=httpx.Response(
                200,
                content=b"",
                headers={"Content-Type": "application/json", "ETag": '"empty-etag"'},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            # GET with empty upstream body
            resp_get = await client.get("/api/v1/compliance/empty-check", headers=eap_bearer(EAP_ALICE))
            assert resp_get.status_code == 200
            assert resp_get.content == b""
            assert resp_get.headers.get("etag") == '"empty-etag"'

            # HEAD request with empty upstream body
            resp_head = await client.head("/api/v1/compliance/empty-check", headers=eap_bearer(EAP_ALICE))
            assert resp_head.status_code == 200
            assert resp_head.content == b""
            assert resp_head.headers.get("etag") == '"empty-etag"'


@pytest.mark.asyncio
async def test_policy_engine_proxy_propagates_allow_header_on_405():
    """Test proxy propagates RFC 9110 Section 15.5.6 Allow header on 405 Method Not Allowed."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.post(f"{policy_engine_url}/api/v1/compliance/gate").mock(
            return_value=httpx.Response(
                405,
                json={"error": "method not allowed"},
                headers={"Allow": "GET, HEAD"},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/api/v1/compliance/gate",
                json={"test": True},
                headers=eap_bearer(EAP_ALICE),
            )
            assert resp.status_code == 405
            assert resp.headers.get("allow") == "GET, HEAD"
            assert resp.json()["error"] == "method not allowed"
            assert route.called


@pytest.mark.asyncio
async def test_policy_engine_proxy_propagates_location_and_etag_headers():
    """Test proxy propagates Location, ETag, and X-Tenant-ID headers from upstream."""
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.post(f"{policy_engine_url}/api/v1/compliance/runs").mock(
            return_value=httpx.Response(
                201,
                json={"run_id": "run-xyz-999"},
                headers={
                    "Location": "/api/v1/compliance/runs/run-xyz-999",
                    "ETag": '"w/run-xyz"',
                    "X-Tenant-ID": EAP_TENANT_A,
                },
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/api/v1/compliance/runs",
                json={"action": "start"},
                headers=eap_bearer(EAP_ALICE),
            )
            assert resp.status_code == 201
            assert resp.headers.get("location") == "/api/v1/compliance/runs/run-xyz-999"
            assert resp.headers.get("etag") == '"w/run-xyz"'
            assert resp.headers.get("x-tenant-id") == EAP_TENANT_A
            assert resp.json()["run_id"] == "run-xyz-999"
            assert route.called


@pytest.mark.asyncio
async def test_proxy_policy_engine_direct_invocation_empty_body_and_204():
    """Directly test proxy_policy_engine function with 204, empty body, and HEAD requests."""
    from routers.policy_engine import proxy_policy_engine
    from starlette.requests import Request
    policy_engine_url = getattr(settings, "policy_engine_url", "http://policy-engine:8081")

    # 1. 204 No Content
    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{policy_engine_url}/api/v1/test_prefix/item").mock(
            return_value=httpx.Response(204, content=b"", headers={"X-Tenant-ID": "tenant-test"})
        )
        scope = {
            "type": "http",
            "method": "GET",
            "path": "/api/v1/test_prefix/item",
            "headers": [(b"authorization", f"Bearer {EAP_ALICE}".encode())],
            "query_string": b"",
        }
        req = Request(scope)
        resp = await proxy_policy_engine(req, "item", "test_prefix", tenant_id="tenant-test")
        assert resp.status_code == 204
        assert resp.body == b""
        assert resp.headers.get("x-tenant-id") == "tenant-test"

    # 2. Direct HEAD request
    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.head(f"{policy_engine_url}/api/v1/test_prefix/status").mock(
            return_value=httpx.Response(200, content=b"", headers={"Content-Type": "application/json", "ETag": '"head-etag"'})
        )
        scope = {
            "type": "http",
            "method": "HEAD",
            "path": "/api/v1/test_prefix/status",
            "headers": [(b"authorization", f"Bearer {EAP_ALICE}".encode())],
            "query_string": b"",
        }
        req = Request(scope)
        resp = await proxy_policy_engine(req, "status", "test_prefix", tenant_id="tenant-test")
        assert resp.status_code == 200
        assert resp.body == b""
        assert resp.headers.get("etag") == '"head-etag"'


