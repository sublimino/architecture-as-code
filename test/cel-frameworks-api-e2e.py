"""CEL frameworks, end to end: real policy-engine binary + fe-signalloom + Postgres.

Run (needs Go, a Postgres you own, and the fe requirements):

    cd d2-signalloom/apps/fe-signalloom/src
    DATABASE_URL=postgresql://postgres:pw@127.0.0.1:<port>/postgres \\
    UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 \\
      --with pytest --with pytest-asyncio --with respx --with-requirements requirements.txt \\
      python -m pytest ../../../../test/cel-frameworks-api-e2e.py -q -p no:cacheprovider

Why pytest and not bats: the assertions are per agent x per control over three
JSON responses, and fe-signalloom's own auth helpers (real RS256 tokens through
the production verifier) are Python; in bats every assertion would be a jq
pipeline.  Skipped unless ``DATABASE_URL`` is set.

What is real and what is not:

* the policy engine is the binary built from ``d2-signalloom/apps/policy-engine``
  at test time, serving the repository ``policy/`` root over HTTP on a free
  loopback port -- no mock;
* fe-signalloom is the real ASGI app (``main.app``) driven in process, with its
  ``policy_engine_url`` pointed at that binary and its pool on a scratch
  database migrated by the real runner and seeded by ``data-reset.sql`` +
  ``data-mock.sql``;
* the agents are the five seeded agents; each gets its workload from a
  ``cis-kubernetes`` integration fixture and its governance context from a
  ``finos-aigf`` integration fixture, picked up from
  ``policy/frameworks/{cis-kubernetes,finos-aigf}/*/fixtures/integration/*.json``.

The expected verdict for every (agent, control) is the fixture's ``expect``
vector, the same one the engine's conformance harness pins.  The test asserts
that exactly those verdicts appear, for the right agent and the right control,
in ``/compliance/posture`` and in ``/compliance/policy/summary``.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import pytest

REPO = Path(__file__).resolve().parents[1]
FE_SRC = REPO / "d2-signalloom" / "apps" / "fe-signalloom" / "src"
# Overridable to prove what an older engine or pack set makes of the same agents.
ENGINE_SRC = Path(os.environ.get("CEL_E2E_ENGINE_SRC") or REPO / "d2-signalloom" / "apps" / "policy-engine")
POLICY_ROOT = Path(os.environ.get("CEL_E2E_POLICY_ROOT") or REPO / "policy")
for path in (FE_SRC, FE_SRC / "tests"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import asyncpg  # noqa: E402
import httpx  # noqa: E402

try:
    import pytest_asyncio
    _async_fixture = pytest_asyncio.fixture
except ImportError:  # pragma: no cover
    pytest_asyncio = None
    _async_fixture = pytest.fixture

DATABASE_URL = os.environ.get("DATABASE_URL")
pytestmark = pytest.mark.skipif(
    DATABASE_URL is None or pytest_asyncio is None,
    reason="DATABASE_URL not set -- the CEL frameworks e2e needs a live Postgres",
)

TENANT = "tenant-demo"
SUBJECT = "cel-e2e-auditor"
AGENTS = [uuid.UUID(f"a0000000-0000-0000-0000-00000000000{i}") for i in range(1, 6)]
#: What the database stores for an engine verdict.
STORED = {"pass": "pass", "fail": "fail", "error": "error", "not_evaluated": "pending"}


def _fixtures(pack: str) -> list[dict[str, Any]]:
    paths = sorted(POLICY_ROOT.glob(f"frameworks/{pack}/*/fixtures/integration/*.json"))
    return [json.loads(p.read_text(encoding="utf-8")) for p in paths]


CIS_FIXTURES = _fixtures("cis-kubernetes")
AIGF_FIXTURES = _fixtures("finos-aigf")


def _plan() -> list[dict[str, Any]]:
    """One seeded agent per row: its object, its agent context, its expectations."""
    assert CIS_FIXTURES and AIGF_FIXTURES, "no integration fixtures under policy/frameworks"
    plan = []
    for i, agent_id in enumerate(AGENTS):
        cis = CIS_FIXTURES[i % len(CIS_FIXTURES)]
        aigf = AIGF_FIXTURES[i % len(AIGF_FIXTURES)]
        plan.append({
            "agent_id": agent_id,
            "object": cis["input"]["object"],
            "context": aigf["input"]["agent"],
            "expect": {
                **{("cis-kubernetes", k): v for k, v in cis["expect"].items()},
                **{("finos-aigf", k): v for k, v in aigf["expect"].items()},
            },
            "fixtures": (cis["name"], aigf["name"]),
        })
    return plan


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def engine_url(tmp_path_factory):
    binary = tmp_path_factory.mktemp("engine") / "policy-engine"
    subprocess.run(["go", "build", "-o", str(binary), "."], cwd=ENGINE_SRC, check=True, timeout=600)
    port = _free_port()
    log = (tmp_path_factory.mktemp("engine-log") / "engine.log").open("w")
    proc = subprocess.Popen(
        [str(binary)],
        env={**os.environ, "PORT": str(port), "POLICY_ROOT": str(POLICY_ROOT),
             "POLICY_BUNDLES_DIR": str(POLICY_ROOT / "bundles"), "POLICY_API_KEYS": ""},
        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
    )
    url = f"http://127.0.0.1:{port}"
    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                if httpx.get(f"{url}/healthz", timeout=1).status_code == 200:
                    break
            except httpx.HTTPError:
                pass
            if proc.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"policy-engine did not come up (rc={proc.poll()})")
            time.sleep(0.2)
        yield url
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


@_async_fixture
async def seeded_pool():
    from db.migrate import apply_migrations

    name = f"signalloom_cel_e2e_{uuid.uuid4().hex[:12]}"
    admin = await asyncpg.connect(DATABASE_URL)
    try:
        await admin.execute(f'CREATE DATABASE "{name}"')
    finally:
        await admin.close()
    pool = await asyncpg.create_pool(_with_database(DATABASE_URL, name), min_size=1, max_size=4)
    try:
        await apply_migrations(pool)
        for script in ("data-reset.sql", "data-mock.sql"):
            await pool.execute((FE_SRC / "db" / script).read_text(encoding="utf-8"))
        yield pool
    finally:
        await pool.close()
        admin = await asyncpg.connect(DATABASE_URL)
        try:
            await admin.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1", name)
            await admin.execute(f'DROP DATABASE IF EXISTS "{name}"')
        finally:
            await admin.close()


@pytest.mark.asyncio
async def test_every_fixture_verdict_reaches_the_api_for_its_agent_and_control(
    engine_url, seeded_pool, monkeypatch,
):
    import api_compat
    from conftest import configure_eap_jwt, eap_bearer
    from main import app

    configure_eap_jwt(monkeypatch)
    monkeypatch.setattr(api_compat.settings, "api_subject_tenants",
                        {**api_compat.settings.api_subject_tenants, SUBJECT: TENANT})
    monkeypatch.setattr(api_compat.settings, "policy_engine_url", engine_url)

    async def get_pool():
        return seeded_pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    plan = _plan()
    for row in plan:
        registered = row["context"].get("registry", {}).get("model_registered") \
            if isinstance(row["context"].get("registry"), dict) else None
        await seeded_pool.execute(
            """UPDATE agent_registry
                  SET workload_spec = $2::jsonb,
                      model_approved = $3,
                      config = config || jsonb_build_object('policy_context', $4::jsonb)
                WHERE id = $1""",
            row["agent_id"], json.dumps(row["object"]),
            registered if isinstance(registered, bool) else None,
            json.dumps(row["context"]),
        )

    control_of = {
        (r["policy_framework_id"], r["policy_check_id"]): str(r["id"])
        for r in await seeded_pool.fetch(
            "SELECT id, policy_framework_id, policy_check_id FROM governance_controls "
            "WHERE tenant_id = $1 AND policy_check_id IS NOT NULL", TENANT)
    }

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        headers = eap_bearer(SUBJECT)
        scan = await client.post(
            "/api/compliance/policy/scan",
            json={"namespace": "agents", "policyVersion": "v1.8.0", "frameworks": []},
            headers=headers,
        )
        assert scan.status_code == 200, scan.text
        scan_body = scan.json()
        assert scan_body["agentsFailed"] == [], scan_body["agentsFailed"]
        assert scan_body["engineInvoked"] is True
        posture = (await client.get("/api/compliance/posture", headers=headers)).json()
        policy = (await client.get("/api/compliance/policy/summary", headers=headers)).json()

    # ---- the scan response carries the engine's status per agent/check ----------
    returned = {(c["agentId"], c["framework"], c["check"]): c["status"] for c in scan_body["checks"]}
    mismatches = []
    for row in plan:
        for (framework, check), verdict in row["expect"].items():
            got = returned.get((str(row["agent_id"]), framework, check))
            if got != verdict:
                mismatches.append(("scan", row["fixtures"], framework, check, verdict, got))

    # ---- /compliance/posture: the stored verdict, per agent, per control --------
    by_agent = {a["agent_id"]: {r["control_id"]: r["status"] for r in a["results"]} for a in posture["agents"]}
    for row in plan:
        for (framework, check), verdict in row["expect"].items():
            control = control_of.get((framework, check))
            if control is None:
                mismatches.append(("unmapped", row["fixtures"], framework, check, verdict, None))
                continue
            got = by_agent[str(row["agent_id"])].get(control)
            if got != STORED[verdict]:
                mismatches.append(("posture", row["fixtures"], framework, check, STORED[verdict], got))
    assert mismatches == [], f"{len(mismatches)} mismatches:\n" + "\n".join(map(str, mismatches))

    # ---- /compliance/policy/summary: per framework, across the five agents ------
    frameworks = {f["name"]: f for f in policy["frameworks"]}
    for name, pack in (("CIS Kubernetes Benchmark", "cis-kubernetes"),
                       ("FINOS AI Governance Framework", "finos-aigf")):
        checks = sorted({check for row in plan for (fw, check) in row["expect"] if fw == pack})
        per_control = {c: [STORED[row["expect"][(pack, c)]] for row in plan] for c in checks}
        assert frameworks[name]["totalControls"] == len(checks), name
        assert frameworks[name]["passedControls"] == sum(
            all(s == "pass" for s in v) for v in per_control.values()), name
        assert frameworks[name]["failedControls"] == sum(
            any(s == "fail" for s in v) for v in per_control.values()), name
    all_stored = [STORED[v] for row in plan for v in row["expect"].values()]
    assert policy["errored"] == all_stored.count("error")
