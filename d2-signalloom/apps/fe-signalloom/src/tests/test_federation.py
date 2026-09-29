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

