"""Tests for the policy review gateway routes (``/api/signals/policy/*``).

Four concerns, in the order they can bite:

1. The routes mount where the dashboard contract says, and refuse an anonymous caller.
2. The review write is gated server-side: a read-only dashboard user gets 403 and the request
   never reaches signal-ingest. This is the contract's named requirement.
3. Every route forwards the right upstream path, query and body, with the gateway credential and
   the acting-tenant/subject headers that make a verdict attributable to a person.
4. Upstream status codes (404, 409, 403) are relayed rather than flattened, and transport faults
   become 502/504 rather than 500.
"""
from __future__ import annotations

import os
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient

from config import settings
from db.connection import set_pool_for_testing
from main import app

import ingest_client
import signal_policy

REVIEWER_SUBJECT = "demo-user"
REVIEWER_EMAIL = "demo-user@signalloom.local"
READ_ONLY_SUBJECT = "analyst@signalloom.local"

GATEWAY_KEY = "g" * 48


@pytest.fixture(autouse=True)
def _no_pool():
    set_pool_for_testing(None)


@pytest.fixture(autouse=True)
def _gateway_key(tmp_path, monkeypatch):
    """Mount a usable gateway credential.

    Without it ``ingest_headers`` raises 503 before any proxy logic runs, which would make every
    assertion below pass or fail for the wrong reason.
    """
    key_file = tmp_path / "token"
    key_file.write_text(GATEWAY_KEY, encoding="utf-8")
    monkeypatch.setenv(ingest_client.KEY_FILE_ENV, str(key_file))
    monkeypatch.setenv("SIGNAL_INGEST_URL", "http://signal-ingest.test:8082")

    # Pin the reviewer allowlist rather than relying on superadmin's built-in defaults.
    #
    # Not fastidiousness: ``settings`` is one process-wide object and
    # tests/test_eap_anonymous_surface.py:97 assigns ``api_superadmin_subjects = set()`` on it
    # directly, with no monkeypatch and so no restore. Depending on the default made this file
    # pass alone and fail in the full suite depending on file order, which is the worst kind of
    # red: it says nothing about the code. Pinning here makes the gate's behaviour a property of
    # this suite rather than of whatever ran before it.
    monkeypatch.setattr(settings, "api_superadmin_subjects", {REVIEWER_SUBJECT})
    monkeypatch.setattr(settings, "api_superadmin_emails", {REVIEWER_EMAIL})


@pytest.fixture(autouse=True)
def _clear_overrides():
    yield
    app.dependency_overrides.clear()


@pytest.fixture()
def client():
    return TestClient(app, raise_server_exceptions=False)


def _as(subject: str, *, email: str | None = None, tenant: str = "tenant-a"):
    """Authenticate every request as ``subject``.

    Only ``authenticated_principal`` is overridden. ``require_policy_reviewer`` is deliberately
    left to run for real, because it is the thing under test: overriding it too would make the
    read-only 403 unfalsifiable.
    """
    from api_compat import Principal, authenticated_principal

    principal = Principal(tenant=tenant, subject=subject, email=email)
    app.dependency_overrides[authenticated_principal] = lambda: principal
    return principal


class _Upstream:
    """A stub signal-ingest that records what it was asked and answers what it was told to."""

    def __init__(self, status=200, payload=None, exc=None, text=None, headers=None, content=None):
        self.status, self.payload, self.exc, self.text = status, payload, exc, text
        self.headers = headers or {}
        self.content = content
        self.calls: list[dict] = []

    def install(self):
        stub = AsyncMock()
        stub.__aenter__ = AsyncMock(return_value=stub)
        stub.__aexit__ = AsyncMock(return_value=False)

        async def request(method, path, **kwargs):
            self.calls.append({"method": method, "path": path, **kwargs})
            if self.exc is not None:
                raise self.exc
            resp = AsyncMock()
            resp.status_code = self.status
            resp.headers = dict(self.headers)
            if self.content is not None:
                resp.content = self.content
            elif self.status == 204:
                resp.content = b""
            elif self.text is not None:
                resp.content = self.text.encode("utf-8")
            else:
                resp.content = b"{}" if self.payload is not None else b"[]"
            if self.text is not None:
                resp.json = lambda: (_ for _ in ()).throw(ValueError("not json"))
            else:
                resp.json = lambda: self.payload if self.payload is not None else []
            return resp

        stub.request = request
        return patch("signal_policy.httpx.AsyncClient", return_value=stub)

    @property
    def call(self):
        assert len(self.calls) == 1, f"expected exactly one upstream call, got {len(self.calls)}"
        return self.calls[0]


# ---------------------------------------------------------------------------
# 1. Mounting and authentication
# ---------------------------------------------------------------------------


class TestRouterMounting:
    def test_policy_routes_registered(self):
        def _flat_routes(routes):
            out = []
            for r in routes:
                inner = getattr(getattr(r, "original_router", None), "routes", None) or getattr(r, "routes", None)
                if inner:
                    out.extend(_flat_routes(inner))
                else:
                    out.append(r)
            return out

        paths = {r.path for r in _flat_routes(app.routes) if hasattr(r, "path")}
        expected = {
            "/api/signals/policy/findings",
            "/api/signals/policy/decisions",
            "/api/signals/policy/rates",
            "/api/signals/policy/decisions/{decision_id}/review",
        }
        assert not expected - paths, f"missing routes: {expected - paths}"

    def test_install_is_idempotent(self):
        before = len(app.routes)
        signal_policy.install_signal_policy_api(app)
        assert len(app.routes) == before, "a second install duplicated the policy routes"

    @pytest.mark.parametrize(
        "method,path",
        [
            ("get", "/api/signals/policy/findings"),
            ("get", "/api/signals/policy/decisions"),
            ("get", "/api/signals/policy/rates"),
            ("post", "/api/signals/policy/decisions/dec-1/review"),
        ],
    )
    def test_unauthenticated_returns_401(self, client, method, path):
        resp = getattr(client, method)(path, **({"json": {"verdict": "needs_info"}} if method == "post" else {}))
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# 2. The review gate -- the contract's named requirement
# ---------------------------------------------------------------------------


class TestReviewGate:
    def test_read_only_user_gets_403_on_review(self, client):
        """An authenticated non-reviewer cannot record a verdict."""
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "false_positive", "note": "benign"},
            )
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "policy_review_forbidden"
        # The gate must refuse BEFORE the proxy: a 403 that still wrote upstream would mean the
        # verdict landed in the evidence and the dashboard was merely told it had not.
        assert upstream.calls == [], "a refused review still reached signal-ingest"

    def test_read_only_user_can_still_read_every_feed(self, client):
        """Read-only means read-only, not locked out: the point is to review what you can see."""
        _as(READ_ONLY_SUBJECT)
        for path in (
            "/api/signals/policy/findings",
            "/api/signals/policy/decisions",
            "/api/signals/policy/rates",
        ):
            upstream = _Upstream(status=200, payload=[])
            with upstream.install():
                resp = client.get(path)
            assert resp.status_code == 200, f"{path} refused a read-only user"
            assert len(upstream.calls) == 1

    def test_reviewer_by_email_is_also_admitted(self, client):
        """The gate reads either identity claim, as ``is_superadmin`` does."""
        _as("some-opaque-sub", email=REVIEWER_EMAIL)
        upstream = _Upstream(status=201, payload={"id": "r1"})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "true_positive", "note": ""},
            )
        assert resp.status_code == 201

    def test_gate_removal_is_detected(self, client, monkeypatch):
        """Monkeypatching is_superadmin to admit everyone lets the read-only POST reach upstream.

        Proves that without the superadmin gate, a non-reviewer request would not be refused
        by the gateway middleware.
        """
        _as(READ_ONLY_SUBJECT)
        monkeypatch.setattr(signal_policy, "is_superadmin", lambda _p: True)
        upstream = _Upstream(status=201, payload={"id": "r1"})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "false_positive", "note": "gate bypass proof"},
            )
        assert resp.status_code == 201
        assert len(upstream.calls) == 1, "when gate is bypassed, request reaches upstream"


# ---------------------------------------------------------------------------
# 3. Forwarding: path, query, body, credential, attribution
# ---------------------------------------------------------------------------


class TestForwarding:
    @pytest.mark.parametrize(
        "gw_path,upstream_path",
        [
            ("/api/signals/policy/findings", "/api/v1/policy/findings"),
            ("/api/signals/policy/decisions", "/api/v1/policy/decisions"),
            ("/api/signals/policy/rates", "/api/v1/policy/rates"),
        ],
    )
    def test_reads_forward_to_the_contracted_upstream_path(self, client, gw_path, upstream_path):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[{"id": "x"}])
        with upstream.install():
            resp = client.get(gw_path)
        assert resp.status_code == 200
        assert resp.json() == [{"id": "x"}]
        assert upstream.call["path"] == upstream_path
        assert upstream.call["method"] == "GET"

    def test_read_query_is_forwarded(self, client):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            client.get("/api/signals/policy/findings?window=10m&limit=25&tenant=tenant-a")
        assert upstream.call["params"] == {"window": "10m", "limit": 25, "tenant": "tenant-a"}

    def test_rates_forwards_the_bucket(self, client):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            client.get("/api/signals/policy/rates?window=90m&bucket=5m")
        assert upstream.call["params"] == {"window": "90m", "bucket": "5m"}

    def test_absent_parameters_are_not_forwarded_as_empty(self, client):
        """An empty ``window=`` upstream is a 400 there; omitting it lets the default apply."""
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            client.get("/api/signals/policy/decisions")
        assert upstream.call["params"] == {}

    def test_review_forwards_the_decision_id_and_a_reassembled_body(self, client):
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={"id": "r1", "decision_id": "dec-1"})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "needs_info", "note": "need the pod spec"},
            )
        assert resp.status_code == 201
        assert upstream.call["path"] == "/api/v1/policy/decisions/dec-1/review"
        assert upstream.call["json"] == {"verdict": "needs_info", "note": "need the pod spec"}

    def test_review_with_changed_note_is_forwarded_as_a_new_assertion(self, client):
        """A review revision with a modified note forwards the updated note to signal-ingest."""
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(
            status=201,
            payload={"id": "r2", "decision_id": "dec-1", "verdict": "true_positive", "note": "revised assessment"},
        )
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "true_positive", "note": "revised assessment"},
            )
        assert resp.status_code == 201
        assert upstream.call["path"] == "/api/v1/policy/decisions/dec-1/review"
        assert upstream.call["json"] == {"verdict": "true_positive", "note": "revised assessment"}

    def test_review_body_is_reassembled_not_relayed(self, client):
        """A caller-supplied reviewer or timestamp must not reach signal-ingest.

        Upstream decodes closed-world and would refuse the extra field anyway, but a proxy that
        forwards whatever arrived is how such a field eventually reaches a handler that trusts it.
        """
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={
                    "verdict": "true_positive",
                    "note": "ok",
                    "reviewer": "ceo@example.com",
                    "reviewed_at": "2020-01-01T00:00:00Z",
                    "tenant_id": "tenant-b",
                },
            )
        assert resp.status_code == 201
        assert set(upstream.call["json"]) == {"verdict", "note"}

    def test_decision_id_is_percent_encoded(self, client):
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            client.post(
                "/api/signals/policy/decisions/dec%20one/review",
                json={"verdict": "needs_info"},
            )
        assert upstream.call["path"] == "/api/v1/policy/decisions/dec%20one/review"

    def test_every_request_carries_the_gateway_key_and_the_acting_identity(self, client):
        """The tenant comes from the validated principal, and the subject names the person.

        signal-ingest reads ``X-SignalLoom-Acting-Subject`` as the reviewer precisely because the
        gateway holds ``tenant:act-for``; without it a verdict would be attributed to the shared
        gateway key rather than to a human.
        """
        _as(REVIEWER_SUBJECT, tenant="tenant-a")
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "true_positive"},
            )
        headers = upstream.call["headers"]
        assert headers["Authorization"] == f"Bearer {GATEWAY_KEY}"
        assert headers[ingest_client.ACTING_SUBJECT_HEADER] == REVIEWER_SUBJECT
        # A WRITE always acts for the user's own tenant, never "*", even for a superadmin.
        assert headers[ingest_client.ACTING_TENANT_HEADER] == "tenant-a"

    def test_a_superadmin_read_acts_for_all_tenants(self, client):
        _as(REVIEWER_SUBJECT, tenant="tenant-a")
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            client.get("/api/signals/policy/decisions")
        assert upstream.call["headers"][ingest_client.ACTING_TENANT_HEADER] == ingest_client.ALL_TENANTS

    def test_a_scoped_read_acts_for_the_users_own_tenant(self, client):
        _as(READ_ONLY_SUBJECT, tenant="tenant-b")
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            client.get("/api/signals/policy/findings")
        assert upstream.call["headers"][ingest_client.ACTING_TENANT_HEADER] == "tenant-b"

    def test_a_missing_gateway_credential_is_503_and_never_an_anonymous_request(self, client, monkeypatch):
        _as(READ_ONLY_SUBJECT)
        monkeypatch.setenv(ingest_client.KEY_FILE_ENV, "/nonexistent/ingest-key/token")
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            resp = client.get("/api/signals/policy/findings")
        assert resp.status_code == 503
        assert resp.json()["error"]["code"] == "ingest_credential_unavailable"
        assert upstream.calls == [], "a request was sent without the gateway credential"


# ---------------------------------------------------------------------------
# 4. Validation and status relay
# ---------------------------------------------------------------------------


class TestValidation:
    @pytest.mark.parametrize(
        "query",
        ["?window=7m", "?window=1h", "?window=5m&since=2026-10-05T00:00:00Z", "?limit=0", "?limit=501"],
    )
    def test_bad_read_query_is_400_without_a_round_trip(self, client, query):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            resp = client.get("/api/signals/policy/findings" + query)
        assert resp.status_code == 400
        assert upstream.calls == []

    @pytest.mark.parametrize("bucket", ["2m", "1h", "60s", "minute"])
    def test_bad_bucket_is_400(self, client, bucket):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            resp = client.get(f"/api/signals/policy/rates?bucket={bucket}")
        assert resp.status_code == 400
        assert upstream.calls == []

    @pytest.mark.parametrize("window", sorted(signal_policy.WINDOWS))
    def test_every_advertised_window_is_accepted(self, client, window):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, payload=[])
        with upstream.install():
            resp = client.get(f"/api/signals/policy/decisions?window={window}")
        assert resp.status_code == 200

    @pytest.mark.parametrize(
        "body",
        [
            {},
            {"verdict": ""},
            {"verdict": "probably"},
            {"verdict": "TRUE_POSITIVE"},
            {"verdict": "true_positive", "note": 7},
            {"verdict": "true_positive", "note": "x" * (signal_policy.MAX_NOTE_CHARS + 1)},
        ],
    )
    def test_bad_review_body_is_400_without_a_round_trip(self, client, body):
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            resp = client.post("/api/signals/policy/decisions/dec-1/review", json=body)
        assert resp.status_code == 400
        assert upstream.calls == []

    @pytest.mark.parametrize("verdict", sorted(signal_policy.VERDICTS))
    def test_every_verdict_in_the_vocabulary_is_accepted(self, client, verdict):
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={"verdict": verdict})
        with upstream.install():
            resp = client.post("/api/signals/policy/decisions/dec-1/review", json={"verdict": verdict})
        assert resp.status_code == 201

    def test_an_absent_note_becomes_an_empty_string(self, client):
        """So the derived review ID upstream is the same whether the field was omitted or empty:
        otherwise the same judgement sent two ways would be two rows."""
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            client.post("/api/signals/policy/decisions/dec-1/review", json={"verdict": "needs_info"})
        assert upstream.call["json"]["note"] == ""
        upstream2 = _Upstream(status=201, payload={})
        with upstream2.install():
            client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "needs_info", "note": None},
            )
        assert upstream2.call["json"]["note"] == ""

    def test_a_note_at_exactly_the_limit_is_accepted(self, client):
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=201, payload={})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "needs_info", "note": "x" * signal_policy.MAX_NOTE_CHARS},
            )
        assert resp.status_code == 201


class TestStatusRelay:
    @pytest.mark.parametrize("status", [400, 403, 404, 409, 429, 500])
    def test_upstream_status_is_relayed_not_flattened(self, client, status):
        """404 for an unknown decision and 409 for an already-recorded verdict are the two the
        dashboard branches on; flattening either to 502 would make a double-click look like an
        outage."""
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(status=status, payload={"error": "upstream said so"})
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "true_positive", "note": "n"},
            )
        assert resp.status_code == status
        assert resp.json() == {"error": "upstream said so"}

    def test_a_non_json_upstream_body_keeps_its_status(self, client):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=502, text="<html>bad gateway</html>")
        with upstream.install():
            resp = client.get("/api/signals/policy/findings")
        assert resp.status_code == 502
        assert resp.json()["error"] == "upstream_non_json"

    def test_connect_error_returns_502(self, client):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(exc=httpx.ConnectError("connection refused"))
        with upstream.install():
            resp = client.get("/api/signals/policy/decisions")
        assert resp.status_code == 502
        assert resp.json()["error"]["code"] == "upstream_unavailable"

    def test_timeout_returns_504(self, client):
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(exc=httpx.TimeoutException("read timeout"))
        with upstream.install():
            resp = client.get("/api/signals/policy/rates")
        assert resp.status_code == 504
        assert resp.json()["error"]["code"] == "upstream_timeout"

    def test_an_unexpected_transport_fault_is_502_not_500(self, client):
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(exc=RuntimeError("socket exploded"))
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "needs_info"},
            )
        assert resp.status_code == 502


class TestUpstreamURL:
    def test_the_base_url_is_read_at_call_time(self, client, monkeypatch):
        """So a config change or a test stub takes effect without reloading the module."""
        monkeypatch.setenv("SIGNAL_INGEST_URL", "http://elsewhere:9999")
        assert signal_policy._signal_ingest_url() == "http://elsewhere:9999"
        monkeypatch.delenv("SIGNAL_INGEST_URL")
        assert signal_policy._signal_ingest_url() == "http://signal-ingest:8082"
        assert os.getenv("SIGNAL_INGEST_URL") is None


# ---------------------------------------------------------------------------
# 5. A superadmin reviewing another tenant's decision
# ---------------------------------------------------------------------------


class _SequencedUpstream:
    """A stub signal-ingest that answers each call from a queue and records all of them."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.calls: list[dict] = []

    def install(self):
        stub = AsyncMock()
        stub.__aenter__ = AsyncMock(return_value=stub)
        stub.__aexit__ = AsyncMock(return_value=False)

        async def request(method, path, **kwargs):
            self.calls.append({"method": method, "path": path, **kwargs})
            status, payload = self.answers.pop(0)
            resp = AsyncMock()
            resp.status_code = status
            resp.headers = {}
            resp.content = b"{}"
            resp.json = lambda: payload
            return resp

        stub.request = request
        return patch("signal_policy.httpx.AsyncClient", return_value=stub)


class TestCrossTenantReview:
    """The Kusari pilot shape: the reviewer is tenant-demo, the decision is kusari's.

    Found on the first live review (2026-10-06): the write acted for the reviewer's own tenant,
    signal-ingest answered 404 for a decision that tenant cannot see, and the verdict was lost.
    """

    def test_superadmin_review_of_another_tenants_decision_acts_for_the_owner(self, client):
        _as(REVIEWER_SUBJECT, tenant="tenant-demo")
        upstream = _SequencedUpstream([
            (404, {"error": "decision not found"}),
            (200, [{"id": "dec-other", "tenant_id": "tenant-x"}, {"id": "dec-k", "tenant_id": "kusari"}]),
            (201, {"id": "r1", "decision_id": "dec-k"}),
        ])
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-k/review",
                json={"verdict": "true_positive", "note": "seen on /signals"},
            )
        assert resp.status_code == 201, resp.text
        assert [c["method"] for c in upstream.calls] == ["POST", "GET", "POST"]
        first, lookup, retry = upstream.calls
        assert first["headers"][ingest_client.ACTING_TENANT_HEADER] == "tenant-demo"
        assert lookup["path"] == "/api/v1/policy/decisions"
        assert lookup["headers"][ingest_client.ACTING_TENANT_HEADER] == ingest_client.ALL_TENANTS
        assert lookup["params"]["limit"] == 100 and "since" in lookup["params"]
        assert retry["headers"][ingest_client.ACTING_TENANT_HEADER] == "kusari"
        assert retry["headers"][ingest_client.ACTING_SUBJECT_HEADER] == REVIEWER_SUBJECT
        assert retry["json"] == {"verdict": "true_positive", "note": "seen on /signals"}

    def test_unknown_decision_stays_404_after_one_lookup(self, client):
        _as(REVIEWER_SUBJECT, tenant="tenant-demo")
        upstream = _SequencedUpstream([
            (404, {"error": "decision not found"}),
            (200, [{"id": "dec-other", "tenant_id": "tenant-x"}]),
        ])
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-missing/review",
                json={"verdict": "needs_info", "note": "where did this go"},
            )
        assert resp.status_code == 404
        assert [c["method"] for c in upstream.calls] == ["POST", "GET"]

    def test_own_tenant_decision_is_one_call(self, client):
        """The common path stays a single upstream write."""
        _as(REVIEWER_SUBJECT, tenant="tenant-demo")
        upstream = _SequencedUpstream([(201, {"id": "r1"})])
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-mine/review",
                json={"verdict": "false_positive", "note": "benign, known job"},
            )
        assert resp.status_code == 201


class TestEmptyBodyAndHeaderPropagation:
    def test_policy_proxy_handles_204_no_content(self, client):
        """Test proxy cleanly forwards 204 No Content without manufacturing error payload."""
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=204, headers={"X-Tenant-ID": "tenant-b"})
        with upstream.install():
            resp = client.get("/api/signals/policy/findings")
        assert resp.status_code == 204
        assert resp.content == b""
        assert resp.headers.get("x-tenant-id") == "tenant-b"

    def test_policy_proxy_handles_empty_body_and_head(self, client):
        """Test proxy cleanly handles empty bodies and HEAD requests without error."""
        _as(READ_ONLY_SUBJECT)
        upstream = _Upstream(status=200, content=b"", headers={"ETag": '"etag-policy-empty"'})
        with upstream.install():
            resp_get = client.get("/api/signals/policy/findings")
            assert resp_get.status_code == 200
            assert resp_get.content == b""
            assert resp_get.headers.get("etag") == '"etag-policy-empty"'

            resp_head = client.head("/api/signals/policy/findings")
            assert resp_head.status_code == 200
            assert resp_head.content == b""
            assert resp_head.headers.get("etag") == '"etag-policy-empty"'

    def test_policy_proxy_propagates_allow_header_on_405(self, client):
        """Test proxy propagates RFC 9110 Section 15.5.6 Allow header on 405 Method Not Allowed."""
        _as(REVIEWER_SUBJECT)
        upstream = _Upstream(
            status=405,
            payload={"error": "method not allowed"},
            headers={"Allow": "GET, HEAD, POST"},
        )
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "true_positive", "note": "ok"},
            )
        assert resp.status_code == 405
        assert resp.headers.get("allow") == "GET, HEAD, POST"
        assert resp.json() == {"error": "method not allowed"}

    def test_policy_proxy_propagates_location_and_etag_headers(self, client):
        """Test proxy propagates Location, ETag, and X-Tenant-ID headers from upstream."""
        _as(REVIEWER_SUBJECT, tenant="tenant-a")
        upstream = _Upstream(
            status=201,
            payload={"id": "review-123"},
            headers={
                "Location": "/api/v1/policy/decisions/dec-1/review/review-123",
                "ETag": '"w/review-123"',
                "X-Tenant-ID": "tenant-a",
            },
        )
        with upstream.install():
            resp = client.post(
                "/api/signals/policy/decisions/dec-1/review",
                json={"verdict": "true_positive", "note": "confirmed"},
            )
        assert resp.status_code == 201
        assert resp.headers.get("location") == "/api/v1/policy/decisions/dec-1/review/review-123"
        assert resp.headers.get("etag") == '"w/review-123"'
        assert resp.headers.get("x-tenant-id") == "tenant-a"
        assert resp.json()["id"] == "review-123"
        assert len(upstream.calls) == 1
