"""Tests for Federated Services reverse proxy, SVID preservation, and tenant scoping in fe-signalloom."""
import json
import os
import pytest
from httpx import AsyncClient, ASGITransport
import respx
import httpx

from main import app
from config import settings
from conftest import eap_bearer, EAP_ALICE, EAP_TENANT_A, EAP_BOB, EAP_TENANT_B

EAP_AUTHENTICATED = True


@pytest.mark.asyncio
async def test_federation_proxy_summary():
    """Test GET /api/v1/federation/summary proxies to signal-ingest injecting X-Tenant-ID."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            return_value=httpx.Response(
                200,
                json={
                    "total_zones": 4,
                    "active_federations": 6,
                    "federated_services": 12,
                    "active_spiffe_ids": 28,
                    "attestation_success_rate": 99.8,
                    "active_alerts": 0,
                },
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 200
            data = resp.json()
            assert data["total_zones"] == 4
            assert data["active_federations"] == 6
            assert route.called
            last_req = route.calls.last.request
            assert "X-Tenant-ID" in last_req.headers
            assert last_req.headers["X-Tenant-ID"] == EAP_TENANT_A


@pytest.mark.asyncio
async def test_federation_proxy_zones_and_services():
    """Test GET /api/v1/federation/zones and /services proxying."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        zones_route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/zones").mock(
            return_value=httpx.Response(
                200,
                json=[
                    {
                        "id": "zone-k8s-prod",
                        "name": "Production Cluster",
                        "trust_domain": "prod.signalloom.internal",
                        "provider": "k8s",
                        "status": "healthy",
                    }
                ],
            )
        )
        services_route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/services").mock(
            return_value=httpx.Response(
                200,
                json=[
                    {
                        "id": "svc-payment",
                        "name": "Payment Gateway",
                        "spiffe_id": "spiffe://prod.signalloom.internal/ns/prod/sa/payment-gw",
                        "status": "active",
                    }
                ],
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            # 1. Zones
            resp_zones = await client.get("/api/v1/federation/zones", headers=eap_bearer(EAP_ALICE))
            assert resp_zones.status_code == 200
            assert resp_zones.json()[0]["id"] == "zone-k8s-prod"
            assert zones_route.called

            # 2. Services
            resp_svc = await client.get("/api/v1/federation/services", headers=eap_bearer(EAP_ALICE))
            assert resp_svc.status_code == 200
            assert resp_svc.json()[0]["id"] == "svc-payment"
            assert services_route.called


@pytest.mark.asyncio
async def test_federation_proxy_authorization_header_preservation():
    """Test Authorization credential header is preserved and forwarded during proxying."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/identities").mock(
            return_value=httpx.Response(200, json=[{"spiffe_id": "spiffe://prod/agent", "status": "verified"}])
        )

        headers = dict(eap_bearer(EAP_ALICE))
        auth_token = headers["Authorization"]

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/identities", headers=headers)
            assert resp.status_code == 200
            assert route.called
            last_req = route.calls.last.request
            assert last_req.headers.get("authorization") == auth_token
            assert last_req.headers.get("x-tenant-id") == EAP_TENANT_A


@pytest.mark.asyncio
async def test_federation_proxy_client_spiffe_header_stripped_at_ingress():
    """Test client-supplied X-SPIFFE-* headers are stripped by ingress middleware."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/identities").mock(
            return_value=httpx.Response(200, json=[{"spiffe_id": "spiffe://prod/agent", "status": "verified"}])
        )

        headers = dict(eap_bearer(EAP_ALICE))
        headers["X-SPIFFE-SVID"] = "spiffe://attacker.fake/forged"

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/identities", headers=headers)
            assert resp.status_code == 200
            assert route.called
            last_req = route.calls.last.request
            # Inbound X-SPIFFE-* stripped at ingress by IdentityHeaderStripMiddleware
            assert "x-spiffe-svid" not in last_req.headers
            assert last_req.headers.get("x-tenant-id") == EAP_TENANT_A


@pytest.mark.asyncio
async def test_federation_proxy_forged_tenant_header_ignored():
    """Test client-supplied X-Tenant-ID header is stripped and overwritten with authenticated tenant."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            return_value=httpx.Response(200, json={"status": "ok"})
        )

        headers = dict(eap_bearer(EAP_ALICE))
        headers["X-Tenant-ID"] = "malicious-tenant-injection"

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=headers)
            assert resp.status_code == 200
            last_req = route.calls.last.request
            assert last_req.headers["X-Tenant-ID"] == EAP_TENANT_A
            assert "malicious-tenant-injection" not in last_req.headers["X-Tenant-ID"]


@pytest.mark.asyncio
async def test_federation_proxy_bob_tenant_scoping():
    """Test Bob receives tenant B header isolation."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            return_value=httpx.Response(200, json={"status": "ok"})
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_BOB))
            assert resp.status_code == 200
            last_req = route.calls.last.request
            assert last_req.headers["X-Tenant-ID"] == EAP_TENANT_B


@pytest.mark.asyncio
async def test_federation_proxy_upstream_connect_error():
    """Test 502 upstream_unavailable returned when signal-ingest is down."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            side_effect=httpx.ConnectError("Connection refused")
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 502
            err = resp.json()
            assert err["error"]["code"] == "upstream_unavailable"


@pytest.mark.asyncio
async def test_federation_proxy_upstream_html_rejection():
    """Test HTML responses from upstream are rejected with 502 invalid_upstream_response."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            return_value=httpx.Response(
                500,
                text="<html><body>500 Internal Server Error</body></html>",
                headers={"Content-Type": "text/html"},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 502
            err = resp.json()
            assert err["error"]["code"] == "invalid_upstream_response"


@pytest.mark.asyncio
async def test_federation_proxy_upstream_404_fallback():
    """Test 404 from upstream returns canonical federation fallback with 200 OK."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            return_value=httpx.Response(
                404,
                text="404 page not found\n",
                headers={"Content-Type": "text/plain; charset=utf-8"},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 200
            data = resp.json()
            assert "zones" in data
            assert "federations" in data
            assert len(data["zones"]) >= 1


@pytest.mark.asyncio
async def test_federation_proxy_upstream_nginx_502_html_rejection():
    """Test upstream 502 Bad Gateway with nginx HTML body is rejected with structured 502 JSON."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
    nginx_html = (
        "<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n"
        "<body>\r\n<center><h1>502 Bad Gateway</h1></center>\r\n"
        "<hr><center>nginx/1.25.4</center>\r\n</body>\r\n</html>"
    )

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/zones").mock(
            return_value=httpx.Response(
                502,
                text=nginx_html,
                headers={"Content-Type": "text/html; charset=utf-8"},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/zones", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 502
            err = resp.json()
            assert "error" in err
            assert err["error"]["code"] == "invalid_upstream_response"
            assert "non-JSON" in err["error"]["message"]


@pytest.mark.asyncio
async def test_federation_proxy_upstream_504_html_rejection():
    """Test upstream 504 Gateway Time-out with HTML body is rejected with structured 502 JSON."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")
    timeout_html = (
        "<!DOCTYPE html><html><head><title>504 Gateway Timeout</title></head>"
        "<body><h1>504 Gateway Timeout</h1></body></html>"
    )

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/services").mock(
            return_value=httpx.Response(
                504,
                text=timeout_html,
                headers={"Content-Type": "text/html"},
            )
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/services", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 502
            err = resp.json()
            assert err["error"]["code"] == "invalid_upstream_response"


@pytest.mark.asyncio
async def test_federation_proxy_upstream_non_json_plain_text():
    """Test upstream returning non-JSON plain text on 500/502 is strictly rejected."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    for status_code in (500, 502, 504):
        with respx.mock(assert_all_called=False) as respx_mock:
            respx_mock.get(f"{signal_ingest_url}/api/v1/federation/policies").mock(
                return_value=httpx.Response(
                    status_code,
                    text=f"Raw text error message for {status_code}",
                    headers={"Content-Type": "text/plain"},
                )
            )

            transport = ASGITransport(app=app)
            async with AsyncClient(transport=transport, base_url="http://test") as client:
                resp = await client.get("/api/v1/federation/policies", headers=eap_bearer(EAP_ALICE))
                assert resp.status_code == 502
                err = resp.json()
                assert err["error"]["code"] == "invalid_upstream_response"


@pytest.mark.asyncio
async def test_federation_proxy_upstream_timeout_exception():
    """Test httpx.TimeoutException produces clean 504 upstream_timeout error envelope."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            side_effect=httpx.TimeoutException("Read timed out")
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 504
            err = resp.json()
            assert err["error"]["code"] == "upstream_timeout"


@pytest.mark.asyncio
async def test_federation_proxy_upstream_remote_protocol_error():
    """Test httpx.RemoteProtocolError produces structured 502 upstream_unavailable."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/summary").mock(
            side_effect=httpx.RemoteProtocolError("Server disconnected unexpectedly")
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/summary", headers=eap_bearer(EAP_ALICE))
            assert resp.status_code == 502
            err = resp.json()
            assert err["error"]["code"] == "upstream_unavailable"


@pytest.mark.asyncio
async def test_federation_proxy_mutating_invalid_content_type():
    """Test POST request with non-JSON Content-Type is rejected with 400 invalid_content_type."""
    headers = dict(eap_bearer(EAP_ALICE))
    headers["Content-Type"] = "text/plain"

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post(
            "/api/v1/federation/policies",
            content="non-json plain text body",
            headers=headers,
        )
        assert resp.status_code == 400
        err = resp.json()
        assert err["error"]["code"] == "invalid_content_type"


@pytest.mark.asyncio
async def test_federation_proxy_mutating_malformed_json():
    """Test POST request with malformed JSON body is rejected with 400 invalid_json."""
    headers = dict(eap_bearer(EAP_ALICE))
    headers["Content-Type"] = "application/json"

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post(
            "/api/v1/federation/policies",
            content="{invalid json structure: true,",
            headers=headers,
        )
        assert resp.status_code == 400
        err = resp.json()
        assert err["error"]["code"] == "invalid_json"


@pytest.mark.asyncio
async def test_federation_proxy_idor_query_param_rejected():
    """Test Alice cannot access tenant B data by specifying ?tenant= or ?tenant_id= in query."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. Cross-tenant attempt via ?tenant=
        resp1 = await client.get(
            f"/api/v1/federation/zones?tenant={EAP_TENANT_B}",
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp1.status_code == 403
        err1 = resp1.json()
        assert err1["error"]["code"] == "tenant_mismatch"

        # 2. Cross-tenant attempt via ?tenant_id=
        resp2 = await client.get(
            f"/api/v1/federation/zones?tenant_id={EAP_TENANT_B}",
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp2.status_code == 403
        err2 = resp2.json()
        assert err2["error"]["code"] == "tenant_mismatch"


@pytest.mark.asyncio
async def test_federation_proxy_idor_path_param_rejected():
    """Test Alice cannot access or mutate tenant B resources via URL path."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # GET under /tenants/{other_tenant}
        resp1 = await client.get(
            f"/api/v1/federation/tenants/{EAP_TENANT_B}/services",
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp1.status_code == 403
        assert resp1.json()["error"]["code"] == "tenant_mismatch"

        # GET under /configurations/{other_tenant}
        resp2 = await client.get(
            f"/api/v1/federation/configurations/{EAP_TENANT_B}",
            headers=eap_bearer(EAP_ALICE),
        )
        assert resp2.status_code == 403
        assert resp2.json()["error"]["code"] == "tenant_mismatch"

        # PUT under /tenants/{other_tenant}/services/svc-1
        headers = dict(eap_bearer(EAP_ALICE))
        headers["Content-Type"] = "application/json"
        resp3 = await client.put(
            f"/api/v1/federation/tenants/{EAP_TENANT_B}/services/svc-1",
            json={"name": "hacked-service"},
            headers=headers,
        )
        assert resp3.status_code == 403
        assert resp3.json()["error"]["code"] == "tenant_mismatch"


@pytest.mark.asyncio
async def test_federation_proxy_idor_body_payload_rejected():
    """Test Alice cannot mutate tenant B configuration via tenant_id in request body."""
    headers = dict(eap_bearer(EAP_ALICE))
    headers["Content-Type"] = "application/json"

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Body specifying tenant_id of Tenant B
        resp1 = await client.post(
            "/api/v1/federation/policies",
            json={"name": "cross-tenant-policy", "tenant_id": EAP_TENANT_B},
            headers=headers,
        )
        assert resp1.status_code == 403
        assert resp1.json()["error"]["code"] == "tenant_mismatch"

        # Body specifying tenant of Tenant B
        resp2 = await client.post(
            "/api/v1/federation/policies",
            json={"name": "cross-tenant-policy", "tenant": EAP_TENANT_B},
            headers=headers,
        )
        assert resp2.status_code == 403
        assert resp2.json()["error"]["code"] == "tenant_mismatch"


@pytest.mark.asyncio
async def test_federation_proxy_matching_tenant_allowed():
    """Test positive control: matching tenant in query or body succeeds."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        respx_mock.get(f"{signal_ingest_url}/api/v1/federation/zones").mock(
            return_value=httpx.Response(200, json=[{"id": "zone-1", "name": "Zone 1"}])
        )

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get(
                f"/api/v1/federation/zones?tenant={EAP_TENANT_A}",
                headers=eap_bearer(EAP_ALICE),
            )
            assert resp.status_code == 200
            assert resp.json()[0]["id"] == "zone-1"


@pytest.mark.asyncio
async def test_federation_proxy_spiffe_spoofing_replaced_with_server_minted_identity():
    """Test client-supplied X-SPIFFE-ID is stripped at ingress and replaced with authentic server identity."""
    signal_ingest_url = os.environ.get("SIGNAL_INGEST_URL", "http://signal-ingest:8082")

    with respx.mock(assert_all_called=False) as respx_mock:
        route = respx_mock.get(f"{signal_ingest_url}/api/v1/federation/identities").mock(
            return_value=httpx.Response(200, json=[{"spiffe_id": "spiffe://prod/agent", "status": "verified"}])
        )

        headers = dict(eap_bearer(EAP_ALICE))
        # Attacker attempts to spoof their SPIFFE identity to claim admin or another cluster
        headers["X-SPIFFE-ID"] = "spiffe://attacker.fake/cluster-admin"
        headers["X-SPIFFE-Trust-Domain"] = "evil.domain"

        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.get("/api/v1/federation/identities", headers=headers)
            assert resp.status_code == 200
            assert route.called
            last_req = route.calls.last.request

            # 1. Attacker-supplied values must NOT reach upstream
            assert "attacker.fake" not in last_req.headers.get("x-spiffe-id", "")
            assert "evil.domain" not in last_req.headers.get("x-spiffe-trust-domain", "")

            # 2. Server must inject authentic identity
            spiffe_header = last_req.headers.get("x-spiffe-id")
            assert spiffe_header is not None
            assert spiffe_header.startswith("spiffe://")
            assert EAP_TENANT_A in spiffe_header or "signalloom" in spiffe_header


