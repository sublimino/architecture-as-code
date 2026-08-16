"""Print the verbatim request/response for each isolation finding.

Not a test -- ``tests/test_tenant_isolation.py`` holds the assertions.  This is
the reproduction, so a reader can see the exact bytes rather than an assertion
about them.  Run it:

    UV_CACHE_DIR=... uv run --python 3.12 --with pytest --with pytest-asyncio \
      --with pytest-xdist --with-requirements requirements.txt \
      python -m tests.demo_isolation_findings

Named ``demo_*`` rather than ``test_*`` on purpose: pytest collects ``test_*``
and would run this as a suite with no assertions in it, which is a green test
that checks nothing.
"""
from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import api_compat  # noqa: E402
from api_compat import settings  # noqa: E402
from db.connection import set_pool_for_testing  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from tests.test_tenant_isolation import (  # noqa: E402
    ALICE,
    TENANT_A,
    TENANT_B,
    GovernancePool,
    RecordingPool,
    _JWKClient,
    bearer,
)
from main import app  # noqa: E402


class _NoopPool:
    async def close(self) -> None:
        return None


def _configure() -> None:
    # main.app's lifespan calls init_db_pool(), which reads DATABASE_URL and
    # raises KeyError without one. Pre-seeding the module pool is what the test
    # fixtures do and keeps this reproduction off any real database.
    set_pool_for_testing(_NoopPool())
    settings.api_jwt_issuer = "https://issuer.test/dex"
    settings.api_jwt_audience = "signalloom-api"
    settings.api_jwt_authorized_party = "signalloom-dashboard"
    settings.api_jwks_url = "https://issuer.test/keys"
    settings.api_subject_tenants = {ALICE: TENANT_A, "bob": TENANT_B}
    api_compat._jwk_client = lambda _url: _JWKClient()


def _show(title: str, method: str, path: str, response) -> None:
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")
    print(f"$ {method} {path}")
    print("  Authorization: Bearer <valid Dex RS256 token, sub=alice, tenant-a>")
    print(f"\n  HTTP {response.status_code}")
    body = response.text
    try:
        body = json.dumps(response.json(), indent=2)
    except ValueError:
        pass
    print("\n".join(f"  {line}" for line in body.splitlines()))


def main() -> int:
    _configure()

    # ---- FINDING: framework catalogue is read across all tenants -----------
    governance = GovernancePool()

    async def governance_pool():
        return governance

    api_compat._get_pool = governance_pool
    set_pool_for_testing(_NoopPool())
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/api/compliance/frameworks", headers=bearer(ALICE))
        _show(
            "FINDING 1  GET /api/compliance/frameworks returns another tenant's framework\n"
            "           governance_frameworks.tenant_id exists and is NOT NULL; the query\n"
            "           does not mention it. The row below belongs to tenant-b.",
            "GET",
            "/api/compliance/frameworks",
            response,
        )
        print("\n  statements issued:")
        for sql, args in governance.statements:
            print(f"    {' '.join(sql.split())}   args={args!r}")

    # ---- FINDING: api-key path tenant is unvalidated -----------------------
    recording = RecordingPool()

    async def recording_pool():
        return recording

    api_compat._get_pool = recording_pool
    set_pool_for_testing(_NoopPool())
    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post("/api/tenants/victimcorp/api-keys/initial", headers=bearer(ALICE))
        _show(
            "FINDING 2  POST /api/tenants/{tenant_id_path}/api-keys/initial\n"
            "           The caller is tenant-a. The path names victimcorp. The path value\n"
            "           is never checked and is embedded in the issued key material.",
            "POST",
            "/api/tenants/victimcorp/api-keys/initial",
            response,
        )
        print("\n  statements issued (storage IS correctly scoped to tenant-a):")
        for sql, args in recording.statements:
            print(f"    {' '.join(sql.split())[:110]}\n      args={args!r}")

    # ---- FINDING: rbac correlation is not tenant-scoped --------------------
    captured: list[str] = []

    async def fake_afm(_client, path: str):
        captured.append(path)
        if path == "/clusters":
            return [{"id": "tenant-b-prod-cluster", "name": "Tenant B Production"}]
        if path.endswith("/rbac"):
            return {
                "subjects": [
                    {"kind": "ServiceAccount", "name": "payroll-writer", "namespace": "tenant-b"}
                ],
                "roles": [],
                "bindings": [],
            }
        return {}

    import rbac_correlation

    rbac_correlation._afm_get_json = fake_afm
    set_pool_for_testing(_NoopPool())
    with TestClient(app, raise_server_exceptions=False) as client:
        listed = client.get("/api/rbac/clusters", headers=bearer(ALICE))
        _show(
            "FINDING 3a GET /api/rbac/clusters lists every cluster KubeSec-AFM knows,\n"
            "           unfiltered by the caller's tenant.",
            "GET",
            "/api/rbac/clusters",
            listed,
        )
        correlated = client.get(
            "/api/rbac/clusters/tenant-b-prod-cluster/correlated", headers=bearer(ALICE)
        )
        _show(
            "FINDING 3b GET /api/rbac/clusters/{cluster_id}/correlated\n"
            "           tenant-a names tenant-b's cluster id and receives its RBAC graph.",
            "GET",
            "/api/rbac/clusters/tenant-b-prod-cluster/correlated",
            correlated,
        )
        print(f"\n  upstream paths requested: {captured}")
        print(f"  caller's tenant ({TENANT_A!r}) present in any of them: "
              f"{any(TENANT_A in path for path in captured)}")

    # ---- PINNED: unknown/foreign agent id is synthesised, not 404'd --------
    async def no_pool():
        return None

    api_compat._get_pool = no_pool
    set_pool_for_testing(_NoopPool())
    with TestClient(app, raise_server_exceptions=False) as client:
        foreign = uuid.UUID("00000000-0000-0000-0000-00000000b0b1")
        response = client.get(f"/api/agents/{foreign}", headers=bearer(ALICE))
        _show(
            "PINNED     GET /api/agents/{agent_id} for an id the caller does not own\n"
            "           Answers 200 with a fabricated agent rather than 404. Sound for\n"
            "           isolation (no existence oracle); a fabricated row in an\n"
            "           evidence product. Product decision -- escalated, not changed.",
            "GET",
            f"/api/agents/{foreign}",
            response,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
