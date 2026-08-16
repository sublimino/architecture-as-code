"""What this service does when a dependency it needs is not there.

The question every test in this file asks is the same one: **when a dependency
fails, does the system fail closed and say so, or does it degrade into a
plausible-looking wrong answer?**  Silent degradation is the defect.  "It didn't
crash" is not a resilience property, so nothing here asserts merely that a
request completed -- every test pins an observable contract: the status code,
the error code in the body, and whether the business row and its audit row
exist afterwards.

Three fault families are covered, and they are not equally well handled:

1. **Upstream proxy faults.** ``fake-integration-proxy`` backs three endpoints.
   The identical ``httpx.ConnectError`` produces three different answers:
   ``GET /network-tests`` fails closed with 502, while ``GET /agents`` and
   ``GET /health/crypto`` return ``200`` with an empty list -- a response that
   is byte-for-byte identical to a healthy service reporting nothing to show.
   Those two are pinned here as characterisation tests that *name the defect*,
   not as approval of it; ``test_one_fault_three_policies`` puts all three side
   by side so the inconsistency is a single failing assertion away from being
   visible.  See the section header for why they are pinned rather than fixed.

2. **Evidence coerced optimistically.**  ``/health/crypto`` is an attestation
   surface, and both of its coercion helpers defaulted to the *reassuring*
   value: an unrecognised proof status became ``pending`` ("not checked yet")
   rather than ``error`` ("we could not tell"), and a proof that failed to
   parse at all was dropped from the list entirely -- three proofs upstream,
   one proof returned, HTTP 200, nothing anywhere saying two went missing.  A
   partial answer presented as a complete one is worse than an empty one,
   because an empty one at least looks wrong.  Both are fixed; the tests below
   were watched failing first.

3. **The database dying mid-request.**  ``_require_pool`` fails closed when the
   pool cannot be *obtained*, but the pool object outliving the database it
   points at is a different fault: ``acquire()`` raises, and every one of those
   used to surface as ``500 internal_error`` -- indistinguishable from a
   NullPointer, and so not actionable by whoever is paged.  A lost connection
   or an acquire timeout is a statement about the database, and it now says so
   with ``503 database_unavailable``.  The constraint-violation tests in the
   same file are the guard against that fix being over-broad: a
   ``NotNullViolationError`` is a bug in this service and must keep reporting
   as one.

**Proving the fault fired.**  A fault injection that quietly fails to take
effect gives a test that passes for the wrong reason, which is the exact failure
mode this file exists to catch.  Every fault-injecting test here has a sibling
that drives the same endpoint through the same fixture with the fault *not*
applied and asserts a different observable outcome.  Where that is not possible,
the assertion is structural (AST) so it cannot go green by luck.

Hermetic: no network, no live cluster, no database.  ``socket.connect`` is
poisoned in the client fixture, so a fault stub that fails to intercept surfaces
as a loud ``AssertionError`` rather than as a timeout that looks like the fault
under test.
"""
from __future__ import annotations

import ast
import asyncio
import copy
import json
import socket
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import asyncpg
import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api_compat
from api_compat import install_compatibility_api, settings

API_COMPAT_SOURCE = Path(api_compat.__file__)

# The in-memory stores are module-level and outlive a single test, so this file
# owns a tenant no other test file writes to.
TENANT = "tenant-resilience-faults"
SUBJECT = "resilience-faults-subject"

# Points at a closed port. Never dialled -- every test either stubs
# ``asyncpg.create_pool`` or injects a pool object directly. Its only job is to
# make ``settings.database_url`` non-empty, which is what tells ``_require_pool``
# that this deployment has declared its audit trail lives in Postgres.
DSN = "postgresql://unused:unused@127.0.0.1:1/unused"

AGENT_BODY = {"name": "resilience-agent", "type": "custom", "owner": "qa@example.test"}

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


# ---------------------------------------------------------------------------
# Auth + client
# ---------------------------------------------------------------------------


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _bearer() -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": SUBJECT,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


def _reset_pool_state(monkeypatch: pytest.MonkeyPatch) -> None:
    """Return ``api_compat``'s pool globals to their cold-start values."""
    monkeypatch.setattr(api_compat, "_pool", None, raising=False)
    monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.UNKNOWN)
    monkeypatch.setattr(api_compat, "_pool_retry_after", 0.0)
    # Recreated lazily per event loop; dropping it is how a test gets a clean one.
    monkeypatch.setattr(api_compat, "_pool_lock", None)
    monkeypatch.setattr(api_compat, "_pool_lock_loop", None)
    monkeypatch.setattr(api_compat, "POOL_RETRY_BACKOFF_SECONDS", 0.0, raising=False)


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    """A client over the *production* mount, with the network poisoned.

    ``install_compatibility_api`` is what ``main`` calls, so this app has
    exactly the routes and exception handlers that ship.
    """
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {SUBJECT: TENANT})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError(
            "external network access is forbidden in these tests -- a fault stub "
            "failed to intercept, so whatever this test observed is a real "
            "connection failure and not the fault under test"
        )

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    _reset_pool_state(monkeypatch)
    # Fixture mode by default. Tests that need an audited deployment set the DSN.
    monkeypatch.setattr(settings, "database_url", "")

    api_compat.reset_tenant_state(TENANT)
    try:
        app = FastAPI()
        install_compatibility_api(app)
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        api_compat.reset_tenant_state(TENANT)


# ---------------------------------------------------------------------------
# Upstream proxy fault injection
# ---------------------------------------------------------------------------


def _stub_proxy(
    monkeypatch: pytest.MonkeyPatch,
    *,
    raises: Exception | None = None,
    payload: Any = None,
    raw_text: str | None = None,
    status: int = 200,
) -> list[str]:
    """Replace ``httpx.AsyncClient`` wholesale and record the URLs asked for.

    Returns the recording list. A test that injects a fault and finds this list
    empty proves the endpoint never reached the proxy at all, which would make
    any conclusion drawn about proxy behaviour worthless.
    """
    requested: list[str] = []

    class _Response:
        status_code = status

        def raise_for_status(self) -> None:
            if status >= 400:
                request = httpx.Request("GET", "http://proxy.invalid/")
                raise httpx.HTTPStatusError(
                    f"upstream returned {status}",
                    request=request,
                    response=httpx.Response(status, request=request),
                )

        def json(self) -> Any:
            if raw_text is not None:
                return json.loads(raw_text)  # raises ValueError on garbage
            return payload

    class _StubClient:
        def __init__(self, *_args: Any, **_kwargs: Any) -> None:
            pass

        async def __aenter__(self) -> "_StubClient":
            return self

        async def __aexit__(self, *_args: Any) -> bool:
            return False

        async def get(self, url: str, **_kwargs: Any) -> _Response:
            requested.append(url)
            if raises is not None:
                raise raises
            return _Response()

        async def post(self, url: str, **_kwargs: Any) -> _Response:
            requested.append(url)
            if raises is not None:
                raise raises
            return _Response()

    monkeypatch.setattr(httpx, "AsyncClient", _StubClient)
    return requested


def _connect_error() -> httpx.ConnectError:
    return httpx.ConnectError(
        "connection refused",
        request=httpx.Request("GET", "http://proxy.invalid/"),
    )


# ===========================================================================
# 1. Upstream proxy unavailable -- one fault, three policies
# ===========================================================================
#
# ``GET /agents`` and ``GET /health/crypto`` are pinned here as they behave
# today rather than changed, deliberately.  Both are load-bearing for the demo
# dashboard, both have existing tests asserting the empty-200
# (``test_agent_discovery_returns_empty_list_when_proxy_fails``,
# ``test_crypto_health_returns_empty_list_when_proxy_fails``), and turning
# either into a 502 is a product decision about what the dashboard renders, not
# a defect fix an implementer should make unilaterally.  What these tests add is
# that the degradation can no longer happen *quietly*: the indistinguishability
# is now a named, asserted property, so anyone changing it has to come here and
# say so.


def test_network_tests_fails_closed_when_the_proxy_is_unreachable(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The positive control, and the standard the other two are measured against.

    Same module, same proxy, same exception type -- and this endpoint refuses to
    answer.  Its presence is what makes the empty-200 of the other two a choice
    rather than an oversight.
    """
    requested = _stub_proxy(monkeypatch, raises=_connect_error())

    response = client.get("/api/network-tests", headers=_bearer())

    assert requested, "the endpoint never called the proxy; the fault never fired"
    assert response.status_code == 502, (
        f"an unreachable network-test runner must not read as a healthy empty "
        f"board, got {response.status_code}: {response.text[:200]}"
    )


def test_network_tests_returns_data_when_the_proxy_is_healthy(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Mechanism proof for the test above: unfaulted, the same call succeeds.

    Without this, a 502 could equally be produced by a broken stub, a bad URL or
    an auth failure, and the fault-injecting test would be measuring nothing.
    """
    _stub_proxy(monkeypatch, payload={"tests": [], "scanStatus": "complete"})

    response = client.get("/api/network-tests", headers=_bearer())

    assert response.status_code == 200, (
        f"the unfaulted path must succeed, got {response.status_code}: "
        f"{response.text[:200]}"
    )


def test_agent_list_cannot_be_told_apart_from_a_healthy_empty_inventory(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """DEFECT PINNED: discovery down and discovery empty are the same response.

    ``GET /agents`` swallows every discovery failure with a bare ``except: pass``
    and carries on.  With no database configured the caller receives
    ``200 {"agents": [], "total": 0}`` whether the discovery proxy is down, slow,
    returning garbage, or genuinely reporting an empty cluster.

    Asserted as *byte equality between the two responses*, which is a stronger
    and more honest statement than asserting the status code of either: it says
    no consumer of this API -- dashboard, alert rule, compliance report -- can
    distinguish "you have no agents" from "we could not look".
    """
    _stub_proxy(monkeypatch, raises=_connect_error())
    while_down = client.get("/api/agents", headers=_bearer())

    _stub_proxy(monkeypatch, payload={"agents": []})
    while_genuinely_empty = client.get("/api/agents", headers=_bearer())

    assert while_down.status_code == while_genuinely_empty.status_code == 200
    assert while_down.json() == while_genuinely_empty.json() == {"agents": [], "total": 0}, (
        "if this assertion fails the defect has been fixed -- update this test "
        "to pin whatever now distinguishes the two states"
    )


def test_agent_list_returns_agents_when_discovery_is_healthy(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Mechanism proof: the empty list above is caused by the fault, not the stub."""
    _stub_proxy(monkeypatch, payload={"agents": [{"id": "a-1", "name": "one"}]})

    response = client.get("/api/agents", headers=_bearer())

    assert response.status_code == 200
    assert response.json()["total"] == 1, (
        "the unfaulted discovery path returned nothing, so the empty list the "
        "fault tests observe proves nothing about the fault"
    )


@pytest.mark.parametrize(
    "label,kwargs",
    [
        ("connection refused", {"raises": _connect_error()}),
        ("read timeout", {"raises": httpx.ReadTimeout("upstream too slow")}),
        ("HTTP 500", {"status": 500, "payload": {"agents": []}}),
        ("non-JSON body", {"raw_text": "<html>502 Bad Gateway</html>"}),
        ("truncated JSON", {"raw_text": '{"agents": [{"id": "a-1"'}),
        ("wrong shape (list, not object)", {"payload": ["a-1", "a-2"]}),
        ("wrong shape (agents is not a list)", {"payload": {"agents": {"id": "a-1"}}}),
        ("null payload", {"payload": None}),
    ],
)
def test_every_discovery_fault_collapses_to_the_same_empty_success(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, label: str, kwargs: dict[str, Any],
) -> None:
    """DEFECT PINNED: eight distinct upstream failures, one indistinguishable answer.

    A slow proxy, a crashed proxy, an HTML error page from an ingress, and a
    schema change upstream all produce ``200 {"agents": [], "total": 0}``.  The
    timeout case matters most operationally -- a dependency that is merely slow
    is the one most likely to be intermittent, and it is reported as a fact
    about the inventory rather than as a fact about the dependency.
    """
    requested = _stub_proxy(monkeypatch, **kwargs)

    response = client.get("/api/agents", headers=_bearer())

    assert requested, f"[{label}] the proxy was never called; the fault never fired"
    assert response.status_code == 200
    assert response.json() == {"agents": [], "total": 0}, (
        f"[{label}] behaviour changed -- re-read this test's docstring"
    )


def test_crypto_health_cannot_be_told_apart_from_a_prover_with_nothing_to_report(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """DEFECT PINNED, and the most consequential of the three.

    ``/health/crypto`` is an *attestation* surface: its proofs are the evidence
    that signing and verification are working.  An unreachable prover returns
    ``200 {"proofs": []}``, identical to a prover reporting no proofs.  Any
    consumer that counts failing proofs -- which is the natural way to read this
    endpoint -- sees zero failures and concludes all is well, at exactly the
    moment nothing is being checked at all.

    Fail-closed is meant to beat degrade-quietly for anything touching evidence.
    This is the clearest place in the module where it does not.
    """
    _stub_proxy(monkeypatch, raises=_connect_error())
    while_down = client.get("/api/health/crypto", headers=_bearer())

    _stub_proxy(monkeypatch, payload={"proofs": []})
    while_genuinely_empty = client.get("/api/health/crypto", headers=_bearer())

    assert while_down.status_code == while_genuinely_empty.status_code == 200
    assert while_down.json() == while_genuinely_empty.json(), (
        "an unreachable prover and a prover with nothing to say are the same "
        "response; if this now fails, the defect has been fixed"
    )
    assert while_down.json()["proofs"] == []


def test_one_fault_three_policies(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The inconsistency, as a single assertion.

    One exception type, one proxy, three endpoints, three different answers.
    Whatever the right policy is, it is not "whichever the author of each
    handler happened to pick".  This test exists so that unifying them is a
    one-line change here rather than an archaeology exercise.
    """
    observed: dict[str, int] = {}
    for path in ("/api/agents", "/api/health/crypto", "/api/network-tests"):
        _stub_proxy(monkeypatch, raises=_connect_error())
        observed[path] = client.get(path, headers=_bearer()).status_code

    assert observed == {
        "/api/agents": 200,          # silent degradation
        "/api/health/crypto": 200,   # silent degradation, on an evidence surface
        "/api/network-tests": 502,   # correct
    }, f"the policies moved: {observed}"


def test_an_unreachable_dependency_is_named_in_the_error_body(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A 502 must say a dependency failed, not "Request failed".

    ``network_tests`` builds the message ``f"network test results unavailable:
    {exc}"`` and raises it as a ``HTTPException``. The ``StarletteHTTPException``
    handler discards ``detail`` for every status it does not special-case and
    substitutes the generic ``request_error`` / "Request failed" -- so the one
    endpoint in this module that correctly fails closed still could not tell the
    caller *what* was unreachable.  A carefully-worded diagnostic that provably
    never reaches anyone is worse than none, because it reads like coverage.
    """
    _stub_proxy(monkeypatch, raises=_connect_error())

    response = client.get("/api/network-tests", headers=_bearer())

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_unavailable", (
        f"the 502 body does not identify the failure as an upstream one: "
        f"{response.text[:200]}"
    )


def test_scan_reports_the_runner_is_unreachable_rather_than_accepting_the_job(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A mutating endpoint whose dependency is down must not look like a success.

    ``POST /network-tests/scan`` forwards the proxy's status code, so the danger
    is the inverse of the read paths: an unreachable runner must not present as
    an accepted job the caller will then wait forever for.
    """
    requested = _stub_proxy(monkeypatch, raises=_connect_error())

    response = client.post("/api/network-tests/scan", headers=_bearer())

    assert requested, "the scan never called the proxy; the fault never fired"
    assert response.status_code == 502, (
        f"expected 502 from an unreachable runner, got {response.status_code}"
    )
    assert response.json()["error"]["code"] == "upstream_unavailable"


def test_scan_forwards_the_runners_own_status_when_it_is_reachable(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Mechanism proof, and a guard on the forwarding contract.

    The proxy owns "already running" (409). Blanket-mapping proxy errors to 502
    here would break the double-submit guard, so the fault path above must not
    be widened into one.
    """
    _stub_proxy(monkeypatch, status=409, payload={"status": "already_running"})

    response = client.post("/api/network-tests/scan", headers=_bearer())

    assert response.status_code == 409, (
        f"the runner's own status must be forwarded unchanged, got "
        f"{response.status_code}"
    )


# ===========================================================================
# 2. Evidence must not be coerced towards the reassuring answer
# ===========================================================================


def _proof(**overrides: Any) -> dict[str, Any]:
    base = {
        "name": "image-signature",
        "kind": "positive",
        "status": "passed",
        "title": "Image signature verifies",
        "description": "cosign verify against the release key",
        "expectation": "signature is valid",
        "evidence": "sha256:abc",
    }
    base.update(overrides)
    return base


def test_an_unrecognised_proof_status_does_not_read_as_not_yet_checked(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """``pending`` is a claim about the future; an unparseable status is not.

    ``_coerce_crypto_status`` mapped every value outside its vocabulary to
    ``pending``.  So a prover that reported ``"fail"``, ``"FAILED"``, ``"denied"``
    or any other spelling of bad news -- a version skew, a vocabulary change, a
    typo in a template -- had that news rewritten to "we haven't got to it yet".
    The default has to be the value that means "we could not tell", which is
    ``error``.
    """
    _stub_proxy(monkeypatch, payload={"proofs": [_proof(status="fail")]})

    response = client.get("/api/health/crypto", headers=_bearer())

    assert response.status_code == 200
    statuses = [p["status"] for p in response.json()["proofs"]]
    assert statuses == ["error"], (
        f"an unrecognised proof status was coerced to {statuses}; anything that "
        f"is not 'error' claims knowledge this service does not have"
    )


def test_a_recognised_proof_status_is_passed_through_unchanged(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Mechanism proof: the coercion above is not simply stamping everything.

    Without this, a fix that returned ``error`` unconditionally would pass the
    test above while destroying the endpoint.
    """
    _stub_proxy(
        monkeypatch,
        payload={"proofs": [
            _proof(name="a", status="passed"),
            _proof(name="b", status="failed"),
            _proof(name="c", status="pending"),
        ]},
    )

    response = client.get("/api/health/crypto", headers=_bearer())

    assert [p["status"] for p in response.json()["proofs"]] == [
        "passed", "failed", "pending",
    ]


def test_a_malformed_proof_is_surfaced_rather_than_dropped(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Three proofs upstream must not become one proof downstream, silently.

    ``_crypto_proof_from_payload`` returns ``None`` for anything it cannot
    parse and the caller's loop skipped it.  The result is the most dangerous
    shape a degraded answer can take: not an empty list, which looks wrong, but
    a *shorter* list, which looks complete.  A prover reporting three proofs of
    which two are malformed rendered as a tidy one-proof board with HTTP 200 and
    no signal anywhere that anything was discarded.

    Malformed proofs are now retained with ``status: error``, so the count is
    honest and the board shows something is wrong with the prover.
    """
    _stub_proxy(
        monkeypatch,
        payload={"proofs": [
            _proof(name="good"),
            _proof(name="missing-title", title=None),
            {"name": "not-even-close"},
        ]},
    )

    response = client.get("/api/health/crypto", headers=_bearer())

    assert response.status_code == 200
    proofs = response.json()["proofs"]
    assert len(proofs) == 3, (
        f"{3 - len(proofs)} of 3 upstream proofs vanished without trace; the "
        f"caller sees a complete-looking board built from partial evidence"
    )
    by_name = {p["name"]: p["status"] for p in proofs}
    assert by_name["good"] == "passed"
    assert by_name["missing-title"] == "error"
    assert [s for n, s in by_name.items() if n not in ("good", "missing-title")] == ["error"]


def test_a_proof_that_is_not_an_object_is_still_counted(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The wrong-type case takes the same path as the wrong-shape case.

    A prover that emits ``["proof-a", "proof-b"]`` instead of objects is a
    schema break, and dropping the entries would report an empty-but-healthy
    board for it.
    """
    _stub_proxy(monkeypatch, payload={"proofs": ["proof-a", 42, None]})

    response = client.get("/api/health/crypto", headers=_bearer())

    proofs = response.json()["proofs"]
    assert len(proofs) == 3, f"non-object proofs were dropped: {proofs}"
    assert {p["status"] for p in proofs} == {"error"}


# ===========================================================================
# 3. The database dying mid-request
# ===========================================================================


@dataclass
class _Committed:
    """The only two tables these mutation tests need to inspect."""

    agent_registry: list[dict[str, Any]] = field(default_factory=list)
    audit_events: list[dict[str, Any]] = field(default_factory=list)


class _FailingConnection:
    """A connection that serves the business write and then dies.

    Writes land in staged state.  Staged state is promoted to committed only if
    the transaction body completes -- so an exception raised on the audit insert
    leaves the business row unpersisted, which is precisely the property under
    test.
    """

    def __init__(self, pool: "_MidRequestFailurePool") -> None:
        self._pool = pool
        self._state = pool.committed

    @asynccontextmanager
    async def transaction(self) -> Any:
        self._state = copy.deepcopy(self._pool.committed)
        try:
            yield
        except BaseException:
            self._state = self._pool.committed
            self._pool.rollbacks += 1
            raise
        self._pool.committed = self._state
        self._pool.commits += 1

    async def fetchrow(self, query: str, *args: Any) -> dict[str, Any] | None:
        if "INSERT INTO agent_registry" in query:
            if self._pool.fail_business_write is not None:
                raise self._pool.fail_business_write
            tenant_id, name, display_name, origin, owner = args
            row = {
                "id": api_compat.uuid.uuid4(),
                "tenant_id": tenant_id,
                "name": name,
                "display_name": display_name,
                "origin": origin,
                "owner": owner,
                "lifecycle_state": "registered",
                "eu_ai_act_risk_class": "limited",
                "model_name": "gpt-5.4-mini",
                "last_transition_at": None,
                "created_at": None,
            }
            self._state.agent_registry.append(row)
            return row
        return None

    async def fetch(self, _query: str, *_args: Any) -> list[dict[str, Any]]:
        return []

    async def execute(self, query: str, *args: Any) -> None:
        if "INSERT INTO audit_events" in query:
            if self._pool.fail_audit_insert is not None:
                raise self._pool.fail_audit_insert
            self._state.audit_events.append({"tenant_id": args[0], "event_type": args[1]})


class _MidRequestFailurePool:
    """A pool object that outlives the database it points at.

    ``_require_pool`` hands this back happily -- the pool exists.  The failure
    happens later, which is a different code path from "the pool could not be
    created" and the one the ``PoolMode`` fix does not cover.
    """

    def __init__(
        self,
        *,
        fail_acquire: Exception | None = None,
        fail_business_write: Exception | None = None,
        fail_audit_insert: Exception | None = None,
    ) -> None:
        self.fail_acquire = fail_acquire
        self.fail_business_write = fail_business_write
        self.fail_audit_insert = fail_audit_insert
        self.committed = _Committed()
        self.commits = 0
        self.rollbacks = 0

    @asynccontextmanager
    async def acquire(self) -> Any:
        if self.fail_acquire is not None:
            raise self.fail_acquire
        yield _FailingConnection(self)

    async def fetch(self, _query: str, *_args: Any) -> list[dict[str, Any]]:
        if self.fail_acquire is not None:
            raise self.fail_acquire
        return list(self.committed.agent_registry)

    async def fetchrow(self, _query: str, *_args: Any) -> dict[str, Any] | None:
        if self.fail_acquire is not None:
            raise self.fail_acquire
        return None

    async def execute(self, _query: str, *_args: Any) -> None:
        if self.fail_acquire is not None:
            raise self.fail_acquire


def _inject_pool(monkeypatch: pytest.MonkeyPatch, pool: Any) -> None:
    """Configure an audited deployment whose pool object is ``pool``.

    The DSN matters: ``_require_pool`` only fails closed when one is set, so a
    test that forgot it would exercise the fixture path and pass for the wrong
    reason.
    """
    monkeypatch.setattr(settings, "database_url", DSN)

    async def _get_pool() -> Any:
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", _get_pool)


@pytest.mark.parametrize(
    "label,failure",
    [
        ("connection lost", asyncpg.exceptions.ConnectionDoesNotExistError("gone")),
        ("server restarted", asyncpg.exceptions.InterfaceError("pool is closing")),
        ("pool exhausted", asyncio.TimeoutError()),
        ("connection reset", ConnectionResetError("peer reset")),
    ],
)
def test_losing_the_database_mid_request_reports_the_database(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, label: str, failure: Exception,
) -> None:
    """503 ``database_unavailable``, not 500 ``internal_error``.

    ``_require_pool`` fails closed when the pool cannot be *created*, and this
    is the other half of that promise: the pool object exists, but the database
    behind it is gone or every connection in it is checked out.  Every one of
    these used to reach the catch-all handler as ``500 internal_error``, which
    tells whoever is paged that this service has a bug -- the single least
    useful thing to say when the actual fault is in Postgres or in capacity.

    Pool exhaustion is in the list on purpose: a fully-subscribed pool is a
    load-shedding condition, and 503 is the status that says "retry", which is
    the behaviour that lets a queue drain instead of a client hammering.
    """
    _inject_pool(monkeypatch, _MidRequestFailurePool(fail_acquire=failure))

    response = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())

    assert response.status_code == 503, (
        f"[{label}] expected 503, got {response.status_code}: {response.text[:200]}"
    )
    assert response.json()["error"]["code"] == "database_unavailable", (
        f"[{label}] error code does not identify the database: {response.text[:200]}"
    )


def test_a_healthy_pool_still_creates_the_agent(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Mechanism proof for the whole of section 3.

    The same fixture, the same endpoint, no fault: 200 and a committed row.
    Without it, every 503 above could be produced by a fake pool too broken to
    serve any request, and the fault injection would be proving nothing.
    """
    pool = _MidRequestFailurePool()
    _inject_pool(monkeypatch, pool)

    response = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())

    assert response.status_code == 200, (
        f"the unfaulted path failed, so the fault tests measure nothing: "
        f"{response.status_code} {response.text[:200]}"
    )
    assert len(pool.committed.agent_registry) == 1
    assert len(pool.committed.audit_events) == 1, (
        "the business row committed without its audit row"
    )
    assert (pool.commits, pool.rollbacks) == (1, 0)


def test_the_database_dying_between_the_write_and_its_audit_row_persists_neither(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The split that already shipped here once, under a harsher fault.

    ``test_write_transactions.py`` covers the audit insert being *rejected* by a
    CHECK constraint.  This is the connection dying underneath it -- a different
    exception class taking a different path out of ``asyncpg`` -- and the
    guarantee has to be the same one: the agent row must not exist, because a
    business write with no audit row is worse than no write at all.

    Asserted on committed state, not on the status code.  A 5xx with the row
    still in the table is the exact defect, and only the state assertion can
    see it.
    """
    pool = _MidRequestFailurePool(
        fail_audit_insert=asyncpg.exceptions.ConnectionDoesNotExistError("gone"),
    )
    _inject_pool(monkeypatch, pool)

    response = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())

    assert response.status_code == 503, (
        f"expected 503, got {response.status_code}: {response.text[:200]}"
    )
    assert pool.committed.agent_registry == [], (
        "the agent row committed even though its audit row never landed -- the "
        "caller was told the request failed for a change that persisted"
    )
    assert pool.committed.audit_events == []
    assert (pool.commits, pool.rollbacks) == (0, 1), (
        f"expected exactly one rollback and no commit, saw "
        f"{pool.commits} commits / {pool.rollbacks} rollbacks"
    )


def test_a_slow_read_reports_a_timeout_rather_than_an_empty_inventory(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A read path must not turn a timed-out query into "nothing here".

    The pool carries ``command_timeout=10``.  ``GET /agents`` issues its
    ``SELECT`` outside any ``try``, so the timeout propagates rather than being
    absorbed into an empty result -- which is the correct choice and the
    opposite of what the same handler does with a discovery timeout twenty lines
    above.  Pinned so a well-meaning ``except: return []`` cannot be added here.
    """
    _stub_proxy(monkeypatch, payload={"agents": []})
    _inject_pool(monkeypatch, _MidRequestFailurePool(fail_acquire=asyncio.TimeoutError()))

    response = client.get("/api/agents", headers=_bearer())

    assert response.status_code >= 500, (
        f"a timed-out query was served as a successful response: "
        f"{response.status_code} {response.text[:200]}"
    )
    assert response.json() != {"agents": [], "total": 0}, (
        "the caller cannot tell a timed-out inventory query from an empty one"
    )


# ===========================================================================
# 4. Constraint violations -- and a guard on section 3 not over-reaching
# ===========================================================================


def test_a_duplicate_name_is_a_conflict_not_a_server_fault(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """409, so the caller can tell a duplicate from an outage.

    This was a real defect: ``agent_registry.name`` is UNIQUE and the violation
    leaked as ``500 internal_error``, so a client retrying could not tell "you
    already have one of these" from "the database is down" -- and the correct
    responses to those are opposite.
    """
    pool = _MidRequestFailurePool(
        fail_business_write=asyncpg.exceptions.UniqueViolationError("duplicate key"),
    )
    _inject_pool(monkeypatch, pool)

    response = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())

    assert response.status_code == 409, (
        f"expected 409, got {response.status_code}: {response.text[:200]}"
    )
    assert response.json()["error"]["code"] == "agent_exists"
    assert pool.committed.agent_registry == []


@pytest.mark.parametrize(
    "label,failure",
    [
        ("NotNull", asyncpg.exceptions.NotNullViolationError("null value")),
        ("Check", asyncpg.exceptions.CheckViolationError("check constraint")),
        ("ForeignKey", asyncpg.exceptions.ForeignKeyViolationError("fk constraint")),
    ],
)
def test_a_schema_violation_is_a_server_fault_and_must_not_be_reported_as_an_outage(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, label: str, failure: Exception,
) -> None:
    """The guard that keeps the 503 mapping honest.

    A ``NotNull``/``Check``/``ForeignKey`` violation means this service sent
    Postgres something Postgres was right to refuse.  That is a bug here, and
    500 is the truthful answer.  Widening the connection-failure mapping to all
    of ``asyncpg.PostgresError`` would relabel every one of these as
    ``database_unavailable`` -- blaming a healthy database for this service's
    own defect, and inviting a retry that can never succeed.

    So this test failing is not a request to add another mapping; it is a signal
    that the 503 rule in section 3 has grown too broad.
    """
    pool = _MidRequestFailurePool(fail_business_write=failure)
    _inject_pool(monkeypatch, pool)

    response = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())

    assert response.status_code == 500, (
        f"[{label}] a schema violation was reported as {response.status_code}; "
        f"if this is now 503 the connection-failure mapping is catching "
        f"constraint errors and blaming the database for a bug in this service"
    )
    assert response.json()["error"]["code"] == "internal_error"
    assert pool.committed.agent_registry == [], (
        f"[{label}] the row committed despite the constraint violation"
    )


def test_the_database_unreachable_boundary_is_explicit() -> None:
    """Exactly which asyncpg errors mean "the database", enumerated.

    The 503 mapping is a tuple of base classes, so its real membership is
    whatever ``asyncpg``'s hierarchy happens to say -- which is invisible at the
    call site and can change under a dependency bump.  A parametrised test can
    only cover the errors someone thought of; this one covers the whole module
    and fails if the set moves in either direction.

    Two members are worth knowing about rather than discovering during an
    incident:

    * ``UnsupportedClientFeatureError`` / ``ClientConfigurationError`` /
      ``UnsupportedServerFeatureError`` are version skew or misconfiguration,
      not transience.  503 invites a retry that will never succeed.  They are
      included anyway because "this service cannot talk to its database" is
      still a truer thing to tell a caller than "internal error", but the
      inclusion is a judgement call and this is where it is recorded.
    * ``TransactionResolutionUnknownError`` means the connection dropped while
      committing, so **whether the write landed is genuinely unknown**.  503 is
      honest about the failure but says nothing about that ambiguity, and no
      caller of this API can currently be told the difference between "did not
      commit" and "may have committed".
    """
    import inspect

    caught = {
        name
        for name, obj in vars(asyncpg.exceptions).items()
        if inspect.isclass(obj)
        and issubclass(obj, BaseException)
        and issubclass(obj, api_compat._DATABASE_UNREACHABLE)
    }

    assert caught == {
        "ClientCannotConnectError",
        "ClientConfigurationError",
        "ConnectionDoesNotExistError",
        "ConnectionFailureError",
        "ConnectionRejectionError",
        "InterfaceError",
        "PostgresConnectionError",
        "ProtocolViolationError",
        "TransactionResolutionUnknownError",
        "UnsupportedClientFeatureError",
        "UnsupportedServerFeatureError",
    }, f"the set of errors reported as database_unavailable changed: {sorted(caught)}"

    # The half that matters most: nothing that means "this service sent Postgres
    # something wrong" may be reported as the database being unavailable.
    service_bugs = {
        "UniqueViolationError",
        "NotNullViolationError",
        "CheckViolationError",
        "ForeignKeyViolationError",
        "UndefinedColumnError",
        "UndefinedTableError",
        "PostgresSyntaxError",
        "DataError",
    }
    misattributed = {
        name
        for name in service_bugs
        if issubclass(getattr(asyncpg.exceptions, name), api_compat._DATABASE_UNREACHABLE)
    }
    assert not misattributed, (
        f"these are bugs in this service but would be reported as the database "
        f"being unavailable, blaming a healthy database and inviting a retry "
        f"that cannot succeed: {sorted(misattributed)}"
    )


# ===========================================================================
# 5. Structural: no mutating handler may reach the database ungated
# ===========================================================================


# The two mutating routes that legitimately do not call ``_require_pool``.
# Anything else appearing here is a handler that can mutate without the audit
# gate, which is the failure this whole file is about.
_UNGATED_MUTATIONS = {
    # Proxies to fake-integration-proxy and touches no table at all; it has its
    # own 502 path for its dependency being down.
    "network_tests_scan",
    # Reads the pool directly and raises its own 503 when it is None. Equivalent
    # in effect, but it cannot distinguish fixture mode from an outage the way
    # ``_require_pool`` does -- so in a fixture deployment this endpoint 503s
    # where every other mutation degrades to the in-memory twin.
    "policy_compliance_scan",
}


def test_every_mutating_handler_gates_on_require_pool() -> None:
    """Asserted on the AST, so a new handler cannot slip through untested.

    The behavioural tests can only cover handlers someone remembered to write a
    test for.  This one covers the twenty-first handler nobody has written yet:
    add a ``@router.post`` that writes to the database without calling
    ``_require_pool`` and this fails, naming it.
    """
    tree = ast.parse(API_COMPAT_SOURCE.read_text())
    mutating_methods = {"post", "put", "patch", "delete"}
    offenders: list[str] = []

    for node in ast.walk(tree):
        if not isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef)):
            continue
        is_mutation = any(
            isinstance(decorator.func if isinstance(decorator, ast.Call) else decorator, ast.Attribute)
            and (decorator.func if isinstance(decorator, ast.Call) else decorator).attr in mutating_methods
            for decorator in node.decorator_list
        )
        if not is_mutation or node.name in _UNGATED_MUTATIONS:
            continue
        gated = any(
            isinstance(call, ast.Call)
            and isinstance(call.func, ast.Name)
            and call.func.id == "_require_pool"
            for call in ast.walk(node)
        )
        if not gated:
            offenders.append(f"{node.name} (line {node.lineno})")

    assert not offenders, (
        "mutating handlers that never call _require_pool, so an unreachable "
        f"audit database cannot fail them closed: {', '.join(offenders)}"
    )


def test_the_ungated_allowlist_still_describes_real_handlers() -> None:
    """An allowlist that names a deleted function silently stops protecting anything.

    Without this, renaming ``policy_compliance_scan`` would leave a stale entry
    excusing a handler that no longer exists while the renamed one goes
    unchecked -- and the test above would still be green.
    """
    tree = ast.parse(API_COMPAT_SOURCE.read_text())
    defined = {
        node.name
        for node in ast.walk(tree)
        if isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef))
    }
    stale = _UNGATED_MUTATIONS - defined
    assert not stale, f"allowlist names handlers that no longer exist: {stale}"


# ===========================================================================
# 6. Two independent pool globals
# ===========================================================================


def test_the_two_pool_globals_are_independent(monkeypatch: pytest.MonkeyPatch) -> None:
    """``db.connection._pool`` and ``api_compat._pool`` say nothing about each other.

    Two modules hold a pool.  ``db.connection`` backs startup and the readiness
    probe; ``api_compat`` backs every request handler.  Setting one leaves the
    other untouched, which means **a green readiness probe is not evidence that
    request handlers have a database** -- readiness can report healthy against
    ``db.connection`` while ``api_compat`` is latched ``UNAVAILABLE`` and every
    mutation is 503ing.

    Pinned rather than fixed: merging them is a real refactor with a real
    blast radius.  What must not happen is someone reading a readiness green as
    covering both.
    """
    import db.connection as db_connection

    sentinel = object()
    monkeypatch.setattr(db_connection, "_pool", None)
    _reset_pool_state(monkeypatch)

    db_connection.set_pool_for_testing(sentinel)
    try:
        assert db_connection.get_pool() is sentinel
        assert api_compat._pool is None, (
            "setting the db.connection pool also set api_compat's; if these are "
            "now one object this test should be deleted, not adjusted"
        )
        assert api_compat._pool_mode is api_compat.PoolMode.UNKNOWN
    finally:
        db_connection.set_pool_for_testing(None)


# ===========================================================================
# 7. Recovery and concurrency
# ===========================================================================


class _SentinelPool:
    """Stands in for an ``asyncpg.Pool``; identity is all that is compared."""


def test_a_mutation_recovers_end_to_end_once_the_database_returns(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The 503 must be a phase, not a state.

    ``test_audit_pool_fail_closed`` proves ``_get_pool`` retries.  This proves
    the recovery reaches the *caller*: the same endpoint that 503s while the
    database is down returns 200 on the next request once it is back, with no
    restart.  The original defect was recoverable only by restarting the
    process, and a unit-level retry test would not have caught that if a handler
    cached the failure itself.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)
    healthy_pool = _MidRequestFailurePool()
    attempts: list[str] = []

    async def _create_pool(*_args: Any, **_kwargs: Any) -> Any:
        attempts.append("attempt")
        if len(attempts) == 1:
            raise OSError("connection refused")
        return healthy_pool

    monkeypatch.setattr(asyncpg, "create_pool", _create_pool)

    while_down = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())
    assert while_down.status_code == 503, (
        f"expected 503 while the database was down, got {while_down.status_code}"
    )
    assert healthy_pool.committed.agent_registry == [], "an unaudited write got through"

    after_recovery = client.post("/api/agents", json=AGENT_BODY, headers=_bearer())
    assert after_recovery.status_code == 200, (
        f"the endpoint stayed latched after the database came back: "
        f"{after_recovery.status_code} {after_recovery.text[:200]}"
    )
    assert len(healthy_pool.committed.agent_registry) == 1
    assert len(healthy_pool.committed.audit_events) == 1
    assert attempts == ["attempt", "attempt"], (
        f"expected exactly two connect attempts, saw {len(attempts)}"
    )


def test_concurrent_first_callers_never_see_a_half_built_pool(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Cold start under load: nobody gets ``None`` while the pool is being built.

    A caller handed ``None`` mid-construction takes the fixture path and its
    mutation goes unaudited -- a fail-open that needs no failure at all, just
    concurrency.  Deterministic rather than timing-dependent: ``create_pool``
    yields ten times, so every gathered coroutine is guaranteed to be scheduled
    while the winner is still inside it.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    sentinel = _SentinelPool()
    attempts: list[int] = []

    async def _slow_create_pool(*_args: Any, **_kwargs: Any) -> _SentinelPool:
        attempts.append(len(attempts) + 1)
        for _ in range(10):
            await asyncio.sleep(0)
        return sentinel

    monkeypatch.setattr(asyncpg, "create_pool", _slow_create_pool)

    async def _race() -> list[Any]:
        return await asyncio.gather(*(api_compat._get_pool() for _ in range(16)))

    results = asyncio.run(_race())

    assert attempts == [1], f"create_pool must run exactly once, saw {len(attempts)}"
    leaked = [i for i, result in enumerate(results) if result is not sentinel]
    assert not leaked, (
        f"{len(leaked)} of 16 concurrent cold-start callers received None while "
        f"the pool was mid-construction (positions {leaked}); each would have "
        f"silently taken the unaudited fixture path"
    )


def test_concurrent_mutations_of_the_same_row_are_serialised_by_the_transaction(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Two writers, one row: both units of work complete or neither leaves a trace.

    Driven at the ``_write`` level rather than through the client because
    ``TestClient`` serialises requests, so an HTTP-level "concurrency" test here
    would prove nothing about interleaving.  What is asserted is the property
    that matters: a transaction that fails part-way leaves no fragment behind
    for the other writer to have observed.
    """
    pool = _MidRequestFailurePool()

    async def _successful_unit() -> None:
        async with api_compat._write(pool) as conn:
            await conn.fetchrow(
                "INSERT INTO agent_registry (...) RETURNING *",
                TENANT, "winner", "winner", "custom", "qa@example.test",
            )
            await conn.execute("INSERT INTO audit_events (...)", TENANT, "agent.created")

    async def _failing_unit() -> None:
        async with api_compat._write(pool) as conn:
            await conn.fetchrow(
                "INSERT INTO agent_registry (...) RETURNING *",
                TENANT, "loser", "loser", "custom", "qa@example.test",
            )
            raise asyncpg.exceptions.ConnectionDoesNotExistError("gone")

    async def _both() -> list[Any]:
        return await asyncio.gather(
            _successful_unit(), _failing_unit(), return_exceptions=True,
        )

    outcomes = asyncio.run(_both())

    assert outcomes[0] is None, f"the successful unit of work failed: {outcomes[0]!r}"
    assert isinstance(outcomes[1], asyncpg.exceptions.ConnectionDoesNotExistError)

    names = [row["name"] for row in pool.committed.agent_registry]
    assert names == ["winner"], (
        f"the rolled-back writer left a row behind: {names}"
    )
    assert (pool.commits, pool.rollbacks) == (1, 1)
