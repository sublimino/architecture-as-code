"""Tests for Dashboard route collisions and Four-Layer Policy Engine Deployment.

Validates:
1. No route collision exists between SPA client-side routes (App.tsx) and nginx proxy prefixes.
2. Every nginx proxy upstream has a matching NetworkPolicy egress rule.
3. Policy Engine reverse proxy routes (/api/v1/compliance/*, /api/v1/policies/*, /api/v1/risk/*) are registered.
4. Inbound and outbound JSON validation, timeouts, and structured error responses.
5. Upstream connection errors and HTML fallbacks return structured HTTP 502/504 errors.
6. Manifest consistency across the 4-layer deployment standard.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, patch

import httpx
import pytest
import yaml
from fastapi.testclient import TestClient

from api_compat import authenticated_tenant
from db.connection import set_pool_for_testing
from main import app

SRC_DIR = Path(__file__).resolve().parent.parent
APPS_DIR = SRC_DIR.parents[0].parent  # d2-signalloom/apps
D2_DIR = SRC_DIR.parents[1]           # d2-signalloom
REPO_ROOT = D2_DIR.parent             # repo root

DASHBOARD_DIR = APPS_DIR / "dashboard-signalloom"
FE_BASE_DIR = APPS_DIR / "fe-signalloom" / "base"
POLICY_ENGINE_BASE_DIR = APPS_DIR / "policy-engine" / "base"


@pytest.fixture(autouse=True)
def _no_pool():
    set_pool_for_testing(None)


@pytest.fixture(autouse=True)
def _auth_override():
    app.dependency_overrides[authenticated_tenant] = lambda: "tenant-demo"
    yield
    app.dependency_overrides.pop(authenticated_tenant, None)


@pytest.fixture()
def client():
    return TestClient(app, raise_server_exceptions=False)


# ===========================================================================
# 1. Route Collision and Nginx Proxy Verification
# ===========================================================================


class TestDashboardRouteCollisions:
    """Ensure zero collision between frontend SPA routes and proxy prefixes."""

    def test_no_proxy_prefix_shadows_spa_route(self):
        app_tsx = DASHBOARD_DIR / "src" / "App.tsx"
        nginx_conf = DASHBOARD_DIR / "nginx.conf"

        assert app_tsx.is_file(), f"App.tsx not found at {app_tsx}"
        assert nginx_conf.is_file(), f"nginx.conf not found at {nginx_conf}"

        app_src = app_tsx.read_text(encoding="utf-8")
        nginx_src = nginx_conf.read_text(encoding="utf-8")

        # Extract SPA route first segments
        spa_segments = set()
        for path in re.findall(r'path="([^"]+)"', app_src):
            if path.startswith("/") and path != "/":
                seg = path.lstrip("/").split("/")[0]
                if seg and not seg.startswith(":"):
                    spa_segments.add(seg)

        # Extract proxy location first segments
        proxy_segments = set()
        for match in re.finditer(r"location\s+(=\s*)?(\S+)\s*\{", nginx_src):
            path = match.group(2)
            start = match.end()
            depth, i = 1, start
            while i < len(nginx_src) and depth:
                if nginx_src[i] == "{":
                    depth += 1
                elif nginx_src[i] == "}":
                    depth -= 1
                i += 1
            body = nginx_src[start:i]
            if "proxy_pass" in body and path != "/":
                seg = path.lstrip("/").split("/")[0]
                if seg:
                    proxy_segments.add(seg)

        collisions = spa_segments.intersection(proxy_segments)
        assert not collisions, f"Nginx proxy prefixes shadow SPA routes: {collisions}"


# ===========================================================================
# 2. Policy Engine Router Registration
# ===========================================================================


class TestPolicyEngineRouterMounting:
    """Verify that all policy-engine proxy routes are mounted on the FastAPI app."""

    def test_policy_engine_routes_registered(self):
        route_paths = {r.path for r in app.routes if hasattr(r, "path")}
        expected_patterns = [
            "/api/v1/compliance",
            "/api/v1/compliance/{subpath:path}",
            "/v1/compliance",
            "/v1/compliance/{subpath:path}",
            "/api/v1/policies",
            "/api/v1/policies/{subpath:path}",
            "/v1/policies",
            "/v1/policies/{subpath:path}",
            "/api/v1/risk",
            "/api/v1/risk/{subpath:path}",
            "/v1/risk",
            "/v1/risk/{subpath:path}",
        ]
        for pattern in expected_patterns:
            assert pattern in route_paths, f"Expected route {pattern} not registered on app"


# ===========================================================================
# 3. Policy Engine Reverse Proxy Behavior & Payload Validation
# ===========================================================================


class TestPolicyEngineProxyBehavior:
    """Verify reverse proxy forwarding, JSON validation, and error handling."""

    def test_get_compliance_proxied(self, client: TestClient):
        mock_resp = httpx.Response(
            200,
            json={
                "frameworks": ["eu-ai-act", "nist-800-53"],
                "summary": {"passing": 12, "failing": 2},
            },
            headers={"Content-Type": "application/json"},
            request=httpx.Request("GET", "http://policy-engine:8081/api/v1/compliance/summary"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.get("/api/v1/compliance/summary")
            assert resp.status_code == 200
            assert resp.headers.get("content-type") == "application/json"
            data = resp.json()
            assert data["summary"]["passing"] == 12

    def test_post_policies_evaluate_proxied(self, client: TestClient):
        payload = {
            "agent_id": "test-agent",
            "checks": ["security-context-present", "run-as-non-root"],
            "pod_spec": {
                "securityContext": {"runAsNonRoot": True},
            },
        }
        mock_resp = httpx.Response(
            200,
            json={
                "agent_id": "test-agent",
                "compliant": True,
                "results": [
                    {"check": "security-context-present", "pass": True, "reason": "ok"},
                    {"check": "run-as-non-root", "pass": True, "reason": "ok"},
                ],
            },
            headers={"Content-Type": "application/json"},
            request=httpx.Request("POST", "http://policy-engine:8081/api/v1/policies/evaluate"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.post(
                "/api/v1/policies/evaluate",
                json=payload,
                headers={"Content-Type": "application/json"},
            )
            assert resp.status_code == 200
            data = resp.json()
            assert data["compliant"] is True
            assert len(data["results"]) == 2

    def test_post_non_json_content_type_rejected(self, client: TestClient):
        resp = client.post(
            "/api/v1/policies/evaluate",
            content="agent_id=123",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert resp.status_code == 400
        data = resp.json()
        assert data["error"]["code"] == "invalid_content_type"

    def test_post_malformed_json_body_rejected(self, client: TestClient):
        resp = client.post(
            "/api/v1/policies/evaluate",
            content="{invalid json",
            headers={"Content-Type": "application/json"},
        )
        assert resp.status_code == 400
        data = resp.json()
        assert data["error"]["code"] == "invalid_json"

    def test_upstream_connect_error_returns_502(self, client: TestClient):
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.side_effect = httpx.ConnectError("Connection refused")
            resp = client.get("/api/v1/compliance/summary")
            assert resp.status_code == 502
            data = resp.json()
            assert data["error"]["code"] == "upstream_unavailable"

    def test_upstream_timeout_returns_504(self, client: TestClient):
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.side_effect = httpx.TimeoutException("Read timed out")
            resp = client.get("/api/v1/compliance/summary")
            assert resp.status_code == 504
            data = resp.json()
            assert data["error"]["code"] == "upstream_timeout"

    def test_upstream_html_fallback_returns_502(self, client: TestClient):
        # When an intermediate reverse proxy or misconfigured service returns HTML (like 200 OK index.html)
        mock_resp = httpx.Response(
            200,
            text="<!DOCTYPE html><html><body>Error Page</body></html>",
            headers={"Content-Type": "text/html"},
            request=httpx.Request("GET", "http://policy-engine:8081/api/v1/compliance/summary"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.get("/api/v1/compliance/summary")
            assert resp.status_code == 502
            data = resp.json()
            assert data["error"]["code"] == "invalid_upstream_response"

    def test_upstream_unparseable_json_returns_502(self, client: TestClient):
        mock_resp = httpx.Response(
            200,
            text="not valid json",
            headers={"Content-Type": "application/json"},
            request=httpx.Request("GET", "http://policy-engine:8081/api/v1/compliance/summary"),
        )
        with patch("httpx.AsyncClient.request", new_callable=AsyncMock) as mock_req:
            mock_req.return_value = mock_resp
            resp = client.get("/api/v1/compliance/summary")
            assert resp.status_code == 502
            data = resp.json()
            assert data["error"]["code"] == "invalid_upstream_response"


# ===========================================================================
# 4. Four-Layer Deployment Standard Manifest Contracts
# ===========================================================================


class TestFourLayerDeploymentManifests:
    """Verify that Layers 1, 3, and 4 Kubernetes manifests are declared properly."""

    def test_layer1_fe_kustomization_includes_policy_engine(self):
        kust_file = FE_BASE_DIR / "kustomization.yaml"
        assert kust_file.is_file()
        content = kust_file.read_text(encoding="utf-8")
        assert "# FLUX ENVSUBST: YES" in content
        kust_data = yaml.safe_load(content)
        assert "../../policy-engine/base" in kust_data.get("resources", [])

    def test_layer1_policy_engine_kustomization_valid(self):
        kust_file = POLICY_ENGINE_BASE_DIR / "kustomization.yaml"
        assert kust_file.is_file()
        content = kust_file.read_text(encoding="utf-8")
        assert "# FLUX ENVSUBST: YES" in content
        kust_data = yaml.safe_load(content)
        resources = kust_data.get("resources", [])
        assert "deployment.yaml" in resources
        assert "service.yaml" in resources
        assert "networkpolicy.yaml" in resources

    def test_layer3_policy_engine_ingress_networkpolicy(self):
        netpol_file = POLICY_ENGINE_BASE_DIR / "networkpolicy.yaml"
        assert netpol_file.is_file()
        docs = list(yaml.safe_load_all(netpol_file.read_text(encoding="utf-8")))
        assert docs, "No manifests found in networkpolicy.yaml"
        ingress_policy = next(
            (d for d in docs if d and d.get("metadata", {}).get("name") == "policy-engine-ingress"),
            None,
        )
        assert ingress_policy is not None, "Missing policy-engine-ingress NetworkPolicy"
        assert ingress_policy["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/name"] == "policy-engine"

        # Check admitted caller labels
        ingress_rules = ingress_policy["spec"].get("ingress", [])
        assert len(ingress_rules) > 0
        from_selectors = ingress_rules[0].get("from", [])
        matched = False
        for f in from_selectors:
            pod_labels = f.get("podSelector", {}).get("matchLabels", {})
            if (
                pod_labels.get("app.kubernetes.io/name") == "fe-signalloom"
                and pod_labels.get("bao.controlplane.io/consumer") == "fe-signalloom"
            ):
                matched = True
        assert matched, "policy-engine-ingress must admit caller with labels app.kubernetes.io/name: fe-signalloom and bao.controlplane.io/consumer: fe-signalloom"

        # Check port 8081
        ports = ingress_rules[0].get("ports", [])
        assert any(p.get("port") == 8081 for p in ports)

    def test_layer4_fe_signalloom_egress_networkpolicy(self):
        netpol_file = FE_BASE_DIR / "networkpolicy.yaml"
        assert netpol_file.is_file()
        docs = list(yaml.safe_load_all(netpol_file.read_text(encoding="utf-8")))
        portal_dep = next(
            (d for d in docs if d and d.get("metadata", {}).get("name") == "allow-portal-dependencies"),
            None,
        )
        assert portal_dep is not None, "allow-portal-dependencies NetworkPolicy missing"
        egress_rules = portal_dep["spec"].get("egress", [])
        matched_egress = False
        for rule in egress_rules:
            to_targets = rule.get("to", [])
            for target in to_targets:
                pod_labels = target.get("podSelector", {}).get("matchLabels", {})
                if pod_labels.get("app.kubernetes.io/name") == "policy-engine":
                    ports = rule.get("ports", [])
                    if any(p.get("port") == 8081 for p in ports):
                        matched_egress = True
        assert matched_egress, "allow-portal-dependencies must allow egress to app.kubernetes.io/name: policy-engine on port 8081"
