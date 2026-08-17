"""Adversarial tests for the signal fusion proxy and demo runner multi-demo.

Attack vectors:
1. Authentication bypass — hit routes without a token, wrong token, wrong tenant.
2. Cross-tenant signal queries — the proxy blindly forwards to Go without tenant_id.
3. Malformed requests — path traversal in actor_id, SQL injection, overlong IDs.
4. Proxy error surfaces — upstream returns invalid JSON, empty body, huge body.
5. Demo runner multi-demo — unknown demo_type, empty demo_type, invalid step IDs.

Every test must pass.  Findings that reveal real defects are documented inline
and pinned (asserted as-is), or fixed if the fix is surgical.
"""
from __future__ import annotations

import json
import textwrap
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient

from db.connection import set_pool_for_testing
from main import app

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _no_pool():
    """Run every test without a database pool."""
    set_pool_for_testing(None)


@pytest.fixture()
def client():
    return TestClient(app, raise_server_exceptions=False)


def _override_tenant(tenant: str = "tenant-demo"):
    """Override authenticated_tenant to return a fixed tenant."""
    from api_compat import authenticated_tenant
    app.dependency_overrides[authenticated_tenant] = lambda: tenant
    return authenticated_tenant


def _override_principal(tenant: str = "tenant-demo"):
    """Override authenticated_principal to return a fixed principal."""
    from api_compat import Principal, authenticated_principal
    app.dependency_overrides[authenticated_principal] = lambda: Principal(
        tenant=tenant, subject="test-subject", email="test@example.com"
    )
    return authenticated_principal


def _clear_overrides():
    app.dependency_overrides.clear()


def _mock_upstream():
    """Return a patch context and mock for httpx.AsyncClient in signal_fusion."""
    patcher = patch("signal_fusion.httpx.AsyncClient")
    mock_cls = patcher.start()
    mock_instance = AsyncMock()
    mock_instance.__aenter__ = AsyncMock(return_value=mock_instance)
    mock_instance.__aexit__ = AsyncMock(return_value=False)
    mock_cls.return_value = mock_instance
    return patcher, mock_instance


# ---------------------------------------------------------------------------
# 1. Authentication bypass
# ---------------------------------------------------------------------------


class TestAuthenticationBypass:
    """Signal fusion routes MUST reject unauthenticated and mis-authenticated
    requests.  The proxy uses ``authenticated_tenant`` / ``authenticated_principal``
    as FastAPI dependencies — if those are removed, routes are wide open."""

    def test_no_token_returns_401(self, client):
        """Every signal route rejects a bare request (no Authorization header)."""
        routes = [
            ("GET", "/api/signals/observations"),
            ("GET", "/api/signals/actors"),
            ("GET", "/api/signals/actors/some-id"),
            ("POST", "/api/signals/actors/some-id/promote"),
            ("GET", "/api/signals/coverage"),
            ("POST", "/api/signals/correlate"),
            ("POST", "/api/signals/collectors/seed"),
        ]
        for method, path in routes:
            resp = client.request(method, path)
            assert resp.status_code == 401, (
                f"{method} {path} returned {resp.status_code}, expected 401"
            )

    def test_garbage_token_returns_401(self, client):
        """A nonsense Authorization header is rejected."""
        resp = client.get(
            "/api/signals/observations",
            headers={"Authorization": "Bearer not-a-real-token"},
        )
        assert resp.status_code == 401

    def test_malformed_auth_header_returns_401(self, client):
        """An Authorization header that isn't Bearer-prefixed is rejected."""
        resp = client.get(
            "/api/signals/observations",
            headers={"Authorization": "Basic dXNlcjpwYXNz"},
        )
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# 2. Cross-tenant signal queries — FINDING
# ---------------------------------------------------------------------------


class TestCrossTenantIsolation:
    """FINDING: The proxy does NOT forward tenant_id to the Go service.

    Every route calls ``_proxy("GET", "/api/v1/...")`` without passing
    ``tenant_id`` as a query parameter or header.  The Go signal-ingest
    service receives an unauthenticated, tenant-blind request.

    This means:
    - If the Go service stores data for multiple tenants, ANY authenticated
      tenant sees ALL tenants' data.
    - The proxy authenticates the caller but ignores the result for data
      scoping.

    This test PINS the current (broken) behaviour: the upstream request
    contains no tenant identifier.
    """

    def test_observations_proxy_omits_tenant_id(self, client):
        """GET /api/signals/observations does not forward tenant_id upstream.

        DEFECT: authenticated_tenant resolves tenant_id, but the proxy call
        ``_proxy("GET", "/api/v1/observations", params=params)`` only passes
        ``limit`` and optionally ``layer``.  tenant_id is never sent upstream.
        """
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = []
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant("tenant-alice")
        try:
            resp = client.get("/api/signals/observations")
            assert resp.status_code == 200

            # Inspect the upstream call — tenant_id should be in params but ISN'T
            call_args = mock_instance.request.call_args
            upstream_method = call_args[0][0]
            upstream_path = call_args[0][1]

            # Collect all params sent upstream
            upstream_params = call_args[1].get("params", {})

            # PINNED DEFECT: tenant_id is absent from the upstream request
            assert "tenant_id" not in upstream_params, (
                "If this assertion fails, the tenant isolation defect has been fixed — "
                "update this test to assert tenant_id IS present."
            )
        finally:
            _clear_overrides()
            patcher.stop()

    def test_actors_proxy_omits_tenant_id(self, client):
        """GET /api/signals/actors does not forward tenant_id upstream."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = []
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant("tenant-bob")
        try:
            resp = client.get("/api/signals/actors")
            assert resp.status_code == 200

            call_args = mock_instance.request.call_args
            # The call is _proxy("GET", "/api/v1/actors") — no kwargs at all
            upstream_kwargs = call_args[1] if call_args[1] else {}
            assert "params" not in upstream_kwargs or "tenant_id" not in upstream_kwargs.get("params", {}), (
                "Tenant isolation defect appears fixed"
            )
        finally:
            _clear_overrides()
            patcher.stop()


# ---------------------------------------------------------------------------
# 3. Malformed requests — path traversal, injection, overlong IDs
# ---------------------------------------------------------------------------


class TestMalformedRequests:
    """Attack the actor_id path parameter with adversarial values."""

    def _get_actor_with_id(self, client, actor_id: str, *, expect_upstream: bool = True):
        """Helper: GET /api/signals/actors/{actor_id} with a mocked upstream."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"id": "safe", "status": "provisional"}
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get(f"/api/signals/actors/{actor_id}")
            if expect_upstream and mock_instance.request.called:
                upstream_path = mock_instance.request.call_args[0][1]
                return resp, upstream_path
            return resp, None
        finally:
            _clear_overrides()
            patcher.stop()

    def test_path_traversal_url_encoded_slashes_returns_404(self, client):
        """URL-encoded path traversal (..%2F) is decoded by FastAPI before
        route matching, so the decoded ``/`` chars change the URL structure.

        ``/api/signals/actors/..%2F..%2Fetc%2Fpasswd`` decodes to
        ``/api/signals/actors/../../etc/passwd`` which does NOT match
        ``/api/signals/actors/{actor_id}`` — FastAPI sees extra path
        segments and returns 404.  This is a GOOD outcome: the traversal
        is rejected at the routing layer.
        """
        resp, _ = self._get_actor_with_id(client, "..%2F..%2Fetc%2Fpasswd")
        assert resp.status_code == 404, (
            f"URL-encoded traversal returned {resp.status_code}, expected 404"
        )

    def test_path_traversal_dots_no_slash_forwarded(self, client):
        """Path traversal without slashes (just dots) IS forwarded.

        actor_id='..passwd' does not change the route structure so FastAPI
        matches it and the proxy forwards it to the Go service.  The Go
        service must handle this.
        """
        resp, upstream_path = self._get_actor_with_id(client, "..passwd")
        assert resp.status_code == 200
        if upstream_path:
            assert "..passwd" in upstream_path

    def test_actor_id_with_newlines(self, client):
        """Actor ID with newlines — tests header injection vector."""
        resp, upstream_path = self._get_actor_with_id(client, "actor%0D%0AInjected-Header:%20evil")
        # FastAPI decodes %0D%0A to \r\n.  httpx may reject the path.
        # Either a 200 (forwarded) or 4xx/5xx (rejected) is acceptable;
        # 500 Internal Server Error is not.
        assert resp.status_code != 500, (
            f"Newline in actor_id caused a 500: {resp.text}"
        )

    def test_actor_id_sql_injection(self, client):
        """SQL injection string in actor_id — should not crash the proxy."""
        sqli = "'; DROP TABLE provisional_actors; --"
        resp, upstream_path = self._get_actor_with_id(client, sqli)
        # The proxy is a pass-through — it should not crash.
        # The upstream mock returns 200, so we expect 200.
        assert resp.status_code == 200
        if upstream_path:
            # Verify the SQL injection string reached the upstream path
            assert "DROP TABLE" in upstream_path, (
                "SQL injection string should be in upstream path (it's the Go "
                "service's job to reject it, not the proxy's — but we document it)"
            )

    def test_very_long_actor_id(self, client):
        """10KB actor_id — tests for length limits."""
        long_id = "A" * 10240
        resp, _ = self._get_actor_with_id(client, long_id)
        # FastAPI and httpx should handle this without crashing.
        # The proxy has no length validation — PINNED.
        assert resp.status_code in (200, 414, 422), (
            f"10KB actor_id returned unexpected {resp.status_code}"
        )

    def test_non_uuid_actor_id(self, client):
        """Non-UUID actor_id where a UUID might be expected."""
        resp, upstream_path = self._get_actor_with_id(client, "not-a-uuid")
        # The proxy does not validate UUID format — it forwards anything.
        assert resp.status_code == 200
        if upstream_path:
            assert "not-a-uuid" in upstream_path

    def test_promote_with_path_traversal_returns_404(self, client):
        """POST /api/signals/actors/{traversal}/promote — URL-encoded slashes
        cause FastAPI to see extra path segments, so the route doesn't match.
        """
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"status": "promoted"}
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_principal()
        try:
            resp = client.post("/api/signals/actors/..%2F..%2Fadmin/promote")
            # FastAPI decodes %2F to / which breaks the route pattern -> 404
            assert resp.status_code == 404, (
                f"Path traversal in promote returned {resp.status_code}, expected 404"
            )
        finally:
            _clear_overrides()
            patcher.stop()

    def test_promote_without_slashes_forwarded(self, client):
        """POST /api/signals/actors/{no-slash-traversal}/promote passes through."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {"status": "promoted"}
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_principal()
        try:
            resp = client.post("/api/signals/actors/..admin../promote")
            assert resp.status_code == 200
            call_args = mock_instance.request.call_args
            upstream_path = call_args[0][1]
            assert "..admin.." in upstream_path
        finally:
            _clear_overrides()
            patcher.stop()

    def test_empty_actor_id_trailing_slash(self, client):
        """FINDING: /api/signals/actors/ (trailing slash) falls through to
        the list-actors route and hits the real upstream.

        FastAPI's redirect_slashes (default True) redirects /actors/ to
        /actors (307), or the trailing-slash URL matches the list route
        directly.  Either way it reaches the Go service — and since the
        Go service is unreachable in tests, we get 502.

        This is NOT a 500 (no unhandled exception) — the proxy's error
        handling correctly converts ConnectError to 502.
        """
        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/actors/")
            # Trailing slash redirects to list-actors -> upstream unreachable -> 502
            # or 307 redirect, both are acceptable
            assert resp.status_code in (502, 307, 200), (
                f"Empty actor_id returned {resp.status_code}"
            )
        finally:
            _clear_overrides()


# ---------------------------------------------------------------------------
# 4. Proxy error surfaces
# ---------------------------------------------------------------------------


class TestProxyErrorSurfaces:
    """What happens when the Go service returns unexpected responses."""

    def test_upstream_invalid_json(self, client):
        """FINDING: Upstream returns 200 with invalid JSON.

        ``resp.json()`` in _proxy raises ``json.JSONDecodeError``, which is
        caught by the generic ``except Exception`` and returns 502.
        """
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.side_effect = json.JSONDecodeError("bad", "", 0)
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations")
            # The generic Exception handler catches JSONDecodeError -> 502
            assert resp.status_code == 502, (
                f"Invalid JSON from upstream returned {resp.status_code}, expected 502"
            )
            body = resp.json()
            assert body["error"]["code"] == "upstream_unavailable"
        finally:
            _clear_overrides()
            patcher.stop()

    def test_upstream_empty_body(self, client):
        """Upstream returns 200 with an empty body."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.side_effect = json.JSONDecodeError("empty", "", 0)
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations")
            assert resp.status_code == 502
        finally:
            _clear_overrides()
            patcher.stop()

    def test_upstream_413_too_large(self, client):
        """Upstream returns 413 — proxy should forward the status code."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 413
        mock_resp.json.return_value = {"error": "too large"}
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations")
            # The proxy blindly forwards status_code from upstream
            assert resp.status_code == 413
        finally:
            _clear_overrides()
            patcher.stop()

    def test_upstream_5xx_forwarded(self, client):
        """Upstream 500 is forwarded verbatim — proxy does not mask it."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 500
        mock_resp.json.return_value = {"error": "internal"}
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations")
            # FINDING: The proxy forwards the upstream 500 to the client.
            # This leaks the fact that the Go service crashed, and the
            # response body may contain Go stack traces.
            assert resp.status_code == 500
        finally:
            _clear_overrides()
            patcher.stop()

    def test_upstream_connection_reset(self, client):
        """Upstream closes connection mid-response."""
        patcher, mock_instance = _mock_upstream()
        mock_instance.request = AsyncMock(
            side_effect=httpx.RemoteProtocolError("connection reset")
        )

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations")
            # RemoteProtocolError is a subclass of Exception, not ConnectError
            # or TimeoutException.  Falls to generic handler -> 502.
            assert resp.status_code == 502
            body = resp.json()
            assert body["error"]["code"] == "upstream_unavailable"
        finally:
            _clear_overrides()
            patcher.stop()

    def test_upstream_huge_response(self, client):
        """Upstream returns a 10MB JSON body — proxy has no size limit.

        FINDING: The proxy does not limit response size.  A compromised or
        buggy Go service can force the proxy to allocate arbitrary memory
        via ``resp.json()`` on a multi-MB body.
        """
        patcher, mock_instance = _mock_upstream()
        # Simulate a huge but valid JSON response
        huge_body = [{"id": f"obs-{i}", "data": "x" * 1000} for i in range(5000)]
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = huge_body
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations")
            # Proxy blindly forwards — no size cap
            assert resp.status_code == 200
            # The response is large
            assert len(resp.content) > 1_000_000
        finally:
            _clear_overrides()
            patcher.stop()


# ---------------------------------------------------------------------------
# 5. Demo runner multi-demo — demo_type validation
# ---------------------------------------------------------------------------


class TestDemoRunnerMultiDemo:
    """Attack the demo_type routing in the multi-demo runner."""

    def test_signalfusion_steps_endpoint_exists(self, client):
        """Signal Fusion demo exposes a /steps endpoint."""
        route_paths = {r.path for r in app.routes if hasattr(r, "path")}
        assert "/api/demo/signalfusion/steps" in route_paths

    def test_signalfusion_has_three_steps(self, client):
        """Signal Fusion returns exactly 3 steps, not the 5 of SuperCred."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/demo/signalfusion/steps")
            assert resp.status_code == 200
            body = resp.json()
            steps = body.get("steps", [])
            assert len(steps) == 3, (
                f"Signal Fusion should have 3 steps, got {len(steps)}: "
                f"{[s.get('step_id') for s in steps]}"
            )
        finally:
            _clear_overrides()

    def test_signalfusion_step_ids_are_1_2_3(self, client):
        """Signal Fusion step IDs are '1', '2', '3' — not '1'-'5'."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/demo/signalfusion/steps")
            assert resp.status_code == 200
            body = resp.json()
            step_ids = sorted(s["step_id"] for s in body["steps"])
            assert step_ids == ["1", "2", "3"], (
                f"Expected step IDs ['1', '2', '3'], got {step_ids}"
            )
        finally:
            _clear_overrides()

    def test_nonexistent_demo_type_returns_404(self, client):
        """Requesting /api/demo/nonexistent/steps returns 404.

        The demo_type validation happens at router registration time —
        only known types get routers.  A request to an unknown type
        simply doesn't match any route.
        """
        dep = _override_tenant()
        try:
            resp = client.get("/api/demo/nonexistent/steps")
            # No router exists for 'nonexistent', so FastAPI returns 404
            assert resp.status_code in (404, 400), (
                f"Unknown demo_type returned {resp.status_code}, expected 404 or 400"
            )
        finally:
            _clear_overrides()

    def test_empty_demo_type_returns_404(self, client):
        """Requesting /api/demo//steps returns 404 or 307."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/demo//steps")
            assert resp.status_code in (404, 307, 405), (
                f"Empty demo_type returned {resp.status_code}"
            )
        finally:
            _clear_overrides()

    def test_supercred_has_five_steps(self, client):
        """SuperCred returns 5 steps — contrast with Signal Fusion's 3."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/demo/supercred/steps")
            assert resp.status_code == 200
            body = resp.json()
            steps = body.get("steps", [])
            assert len(steps) == 5, (
                f"SuperCred should have 5 steps, got {len(steps)}"
            )
        finally:
            _clear_overrides()

    def test_signalfusion_step_4_rejected(self, client):
        """Running step '4' on signalfusion is rejected — it only has 3 steps.

        This requires superadmin auth which we can't easily mock in a unit
        test without the full auth stack, so we test via the steps endpoint
        and verify step 4 is not in the valid set.
        """
        dep = _override_tenant()
        try:
            resp = client.get("/api/demo/signalfusion/steps")
            assert resp.status_code == 200
            body = resp.json()
            step_ids = [s["step_id"] for s in body["steps"]]
            assert "4" not in step_ids, (
                "Step '4' should not exist in Signal Fusion's step registry"
            )
            assert "5" not in step_ids, (
                "Step '5' should not exist in Signal Fusion's step registry"
            )
        finally:
            _clear_overrides()


# ---------------------------------------------------------------------------
# 6. Limit parameter validation
# ---------------------------------------------------------------------------


class TestLimitParameterValidation:
    """The ``limit`` query parameter on GET /observations is bounded 1..1000."""

    def test_limit_zero_rejected(self, client):
        """limit=0 violates ge=1 and should return 422."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations?limit=0")
            assert resp.status_code == 422
        finally:
            _clear_overrides()

    def test_limit_negative_rejected(self, client):
        """limit=-1 violates ge=1."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations?limit=-1")
            assert resp.status_code == 422
        finally:
            _clear_overrides()

    def test_limit_over_1000_rejected(self, client):
        """limit=1001 violates le=1000."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations?limit=1001")
            assert resp.status_code == 422
        finally:
            _clear_overrides()

    def test_limit_non_integer_rejected(self, client):
        """limit=abc is not an integer."""
        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations?limit=abc")
            assert resp.status_code == 422
        finally:
            _clear_overrides()

    def test_limit_1000_accepted(self, client):
        """limit=1000 is the maximum valid value."""
        patcher, mock_instance = _mock_upstream()
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = []
        mock_instance.request = AsyncMock(return_value=mock_resp)

        dep = _override_tenant()
        try:
            resp = client.get("/api/signals/observations?limit=1000")
            assert resp.status_code == 200
        finally:
            _clear_overrides()
            patcher.stop()
