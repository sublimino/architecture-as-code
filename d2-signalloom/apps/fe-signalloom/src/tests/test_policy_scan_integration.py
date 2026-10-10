"""Per-agent policy scan against a real PostgreSQL (Tier 2).

Skipped unless ``DATABASE_URL`` is set.  A scratch database is created,
migrated with the real runner, seeded with ``db/data-mock.sql``, scanned
through the HTTP API with the policy engine mocked by respx, and then read
back through ``/compliance/posture``, ``/compliance/summary`` and
``/compliance/policy/summary``.  Every verdict is asserted per agent and per
control -- the defect this guards against stamped one verdict on every agent.
"""
from __future__ import annotations

import asyncio
import json
import os
import uuid
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient

try:
    import pytest_asyncio
    _async_fixture = pytest_asyncio.fixture
except ImportError:  # pragma: no cover
    pytest_asyncio = None
    _async_fixture = pytest.fixture

import api_compat
from config import settings
from conftest import eap_bearer
from db.migrate import apply_migrations
from main import app

EAP_AUTHENTICATED = True
DATABASE_URL = os.environ.get("DATABASE_URL")
pytestmark = pytest.mark.skipif(
    DATABASE_URL is None or pytest_asyncio is None,
    reason="DATABASE_URL not set -- policy scan integration tests require a live Postgres",
)

DB_DIR = Path(__file__).resolve().parents[1] / "db"
#: The demo load path (scripts/signalloom-data.sh mock): reset, then mock.
SEED = [DB_DIR / "data-reset.sql", DB_DIR / "data-mock.sql"]
ENGINE = f"{getattr(settings, 'policy_engine_url', 'http://policy-engine:8081')}/api/v1/compliance/scan"
TENANT = "tenant-demo"
SUBJECT = "demo-auditor"

CIS = [
    "sa-token-automount-disabled", "no-privileged-containers", "no-host-pid", "no-host-ipc",
    "no-host-network", "no-privilege-escalation", "no-root-containers", "no-net-raw",
    "no-added-capabilities", "capabilities-dropped-all", "no-windows-hostprocess",
    "no-hostpath-volumes", "no-host-ports", "no-secrets-in-env", "seccomp-runtime-default",
    "security-context-applied", "no-default-namespace",
]
AIGF = [
    "rag-ingestion-sensitive-data-filtered", "prompt-injection-guardrail-active",
    "output-leakage-filter-active", "inference-rate-limit-configured",
    "registered-model-registry-entry", "model-version-pinned", "user-authn-and-rbac-enforced",
    "ai-data-encrypted-at-rest", "tool-grants-least-privilege", "mcp-servers-allowlisted",
    "no-long-lived-credentials-exposed", "high-impact-actions-human-approved",
    "ai-interaction-audit-logging", "spend-budget-alerting-configured",
    "decision-explainability-metadata", "decision-audit-tamper-evident",
]

LANCELOT = uuid.UUID("a0000000-0000-0000-0000-000000000001")
DENNIS = uuid.UUID("a0000000-0000-0000-0000-000000000002")
BLACK_KNIGHT = uuid.UUID("a0000000-0000-0000-0000-000000000003")
PATSY = uuid.UUID("a0000000-0000-0000-0000-000000000004")
ROBIN = uuid.UUID("a0000000-0000-0000-0000-000000000005")


def pod(name: str) -> dict[str, Any]:
    return {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": "agents"},
            "spec": {"containers": [{"name": "runtime", "image": f"ghcr.io/x/{name}:1"}]}}


#: What the (mocked) engine answers for each agent, keyed by the workload name
#: the scan sent.  None = the agent has no workload on record.
VERDICTS: dict[str | None, dict[str, str]] = {
    "lancelot": {**{c: "pass" for c in CIS}, **{c: "pass" for c in AIGF}, "no-privileged-containers": "fail",
                 "no-default-namespace": "fail",
                 "registered-model-registry-entry": "pass", "prompt-injection-guardrail-active": "pass",
                 "decision-explainability-metadata": "fail"},
    "dennis": {**{c: "fail" for c in CIS}, **{c: "fail" for c in AIGF}, "sa-token-automount-disabled": "pass",
               "registered-model-registry-entry": "pass", "prompt-injection-guardrail-active": "error",
               "decision-explainability-metadata": "fail"},
    "black-knight": {**{c: ("pass" if i < 5 else "fail") for i, c in enumerate(CIS)},
                     **{c: "fail" for c in AIGF}},
    # What the real engine answers with no object (verified against the binary:
    # an absent object is bound to {}, and every CIS check FAILS on {}).  The
    # scan must never ask it, and never store this: see H1 below.
    None: {**{c: "fail" for c in CIS}, **{c: "fail" for c in AIGF}},
}
#: An agent with no workload on record: the scan does not ask the engine about
#: an object-only pack, and stores those controls as pending with no assessed_at.
NO_WORKLOAD = "pending"
WORKLOAD = {LANCELOT: "lancelot", DENNIS: "dennis", BLACK_KNIGHT: "black-knight", PATSY: None, ROBIN: None}
CONTEXT = {
    LANCELOT: {"guardrails": {"prompt_injection_filter": True}},
    DENNIS: {"governance": {"decision_explainability": False}},
    BLACK_KNIGHT: None, PATSY: None, ROBIN: None,
}


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


@_async_fixture
async def seeded_pool():
    name = f"signalloom_scan_{uuid.uuid4().hex[:12]}"
    admin = await asyncpg.connect(DATABASE_URL)
    try:
        await admin.execute(f'CREATE DATABASE "{name}"')
    finally:
        await admin.close()
    pool = await asyncpg.create_pool(_with_database(DATABASE_URL, name), min_size=1, max_size=4)
    try:
        await apply_migrations(pool)
        for script in SEED:
            await pool.execute(script.read_text(encoding="utf-8"))
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


def engine_answer(request: httpx.Request) -> httpx.Response:
    body = json.loads(request.content)
    workload = body.get("object", {}).get("metadata", {}).get("name") if "object" in body else None
    verdicts = VERDICTS[workload]
    out = []
    for framework, checks in (("cis-kubernetes", CIS), ("finos-aigf", AIGF)):
        if framework not in body["frameworks"]:
            continue
        for check in checks:
            status = verdicts[check]
            out.append({
                "framework": framework, "controlSet": "set", "control": check, "check": check,
                "checkName": check, "controlId": check, "frameworkVersion": body["policyVersion"],
                "passed": status == "pass", "status": status,
                **({"error": "no such key"} if status == "error" else {}),
                "policyVersion": body["policyVersion"], "ale": 0.0, "var95": 0.0, "tvar": 0.0, "carriedGbp": 0.0,
                "scanTimestamp": "2026-10-10T12:00:00Z", "calibrationSource": "industry-indicative",
            })
    return httpx.Response(200, json=out)


@pytest.mark.asyncio
async def test_seed_maps_every_cis_and_aigf_check_to_one_control(seeded_pool):
    rows = await seeded_pool.fetch(
        """SELECT policy_framework_id, policy_check_id FROM governance_controls
            WHERE tenant_id = $1 AND policy_framework_id IS NOT NULL""", TENANT)
    got = sorted((r["policy_framework_id"], r["policy_check_id"]) for r in rows)
    assert got == sorted([("cis-kubernetes", c) for c in CIS] + [("finos-aigf", c) for c in AIGF])
    # CEL lives in the pack, not in prose descriptions.
    assert await seeded_pool.fetchval(
        "SELECT count(*) FROM governance_controls WHERE description LIKE '%CEL:%'") == 0
    counts = {r["name"]: r["control_count"] for r in await seeded_pool.fetch(
        "SELECT name, control_count FROM governance_frameworks WHERE tenant_id = $1", TENANT)}
    assert counts["CIS Kubernetes Benchmark"] == 17
    assert counts["FINOS AI Governance Framework"] == 16


@pytest.mark.asyncio
async def test_error_is_a_storable_status(seeded_pool):
    await seeded_pool.execute(
        """INSERT INTO agent_compliance_results (tenant_id, agent_id, control_id, status)
           VALUES ($1, $2, 'c0000000-0000-0000-0000-000000000007', 'error')""", TENANT, PATSY)
    with pytest.raises(asyncpg.CheckViolationError):
        await seeded_pool.execute(
            """INSERT INTO agent_compliance_results (tenant_id, agent_id, control_id, status)
               VALUES ($1, $2, 'c0000000-0000-0000-0000-000000000008', 'maybe')""", TENANT, PATSY)


@pytest.mark.asyncio
async def test_scan_lands_every_verdict_on_its_agent_and_control_and_the_api_reports_it(
    seeded_pool, monkeypatch,
):
    async def get_pool():
        return seeded_pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    monkeypatch.setattr(settings, "api_subject_tenants", {**settings.api_subject_tenants, SUBJECT: TENANT})

    for agent_id, workload in WORKLOAD.items():
        await seeded_pool.execute(
            """UPDATE agent_registry
                  SET workload_spec = $2::jsonb,
                      config = config || jsonb_build_object('policy_context', $3::jsonb)
                WHERE id = $1""",
            agent_id,
            json.dumps(pod(workload)) if workload else None,
            json.dumps(CONTEXT[agent_id]) if CONTEXT[agent_id] is not None else None,
        )
    before = {(r["agent_id"], r["control_id"]): r["status"] for r in await seeded_pool.fetch(
        "SELECT agent_id, control_id, status FROM agent_compliance_results")}

    control_of = {r["policy_check_id"]: r["id"] for r in await seeded_pool.fetch(
        "SELECT id, policy_check_id FROM governance_controls WHERE policy_check_id IS NOT NULL")}

    with respx.mock(assert_all_called=True) as mock:
        route = mock.post(ENGINE).mock(side_effect=engine_answer)
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/api/compliance/policy/scan",
                json={"namespace": "agents", "policyVersion": "v1.0.0", "frameworks": []},
                headers=eap_bearer(SUBJECT),
            )
            assert resp.status_code == 200, resp.text
            assert resp.json()["engineInvoked"] is True
            assert resp.json()["agentsScanned"] == 5
            # Three agents with a workload x two packs, two without x AIGF only.
            assert route.call_count == 8
            assert all("object" in json.loads(c.request.content) for c in route.calls
                       if json.loads(c.request.content)["frameworks"] == ["cis-kubernetes"])
            gaps = resp.json()["controlGaps"]
            assert sorted((g["agentId"], g["check"], g["reason"], g["stored"]) for g in gaps) == sorted(
                (str(a), c, "no_workload", "pending") for a, w in WORKLOAD.items() if w is None for c in CIS)

            # The agent context each agent was scanned with came from ITS row.
            sent = {json.loads(c.request.content).get("object", {}).get("metadata", {}).get("name"):
                    json.loads(c.request.content)["agent"] for c in route.calls}
            assert sent["lancelot"] == {"registry": {"model_registered": True},
                                        "guardrails": {"prompt_injection_filter": True}}
            assert sent["dennis"] == {"registry": {"model_registered": True},
                                      "governance": {"decision_explainability": False}}

            posture = (await client.get("/api/compliance/posture", headers=eap_bearer(SUBJECT))).json()
            summary = (await client.get("/api/compliance/summary", headers=eap_bearer(SUBJECT))).json()
            policy = (await client.get("/api/compliance/policy/summary", headers=eap_bearer(SUBJECT))).json()

    # ---- expected state: seed rows untouched, plus exactly the new verdicts ----
    expected = dict(before)
    for agent_id, workload in WORKLOAD.items():
        for check, status in VERDICTS[workload].items():
            expected[(agent_id, control_of[check])] = (
                NO_WORKLOAD if workload is None and check in CIS else status)

    stored = {(r["agent_id"], r["control_id"]): r["status"] for r in await seeded_pool.fetch(
        "SELECT agent_id, control_id, status FROM agent_compliance_results")}
    assert stored == expected

    by_agent = {a["agent_id"]: {r["control_id"]: r["status"] for r in a["results"]} for a in posture["agents"]}
    for agent_id in WORKLOAD:
        assert by_agent[str(agent_id)] == {
            str(control): status for (aid, control), status in expected.items() if aid == agent_id
        }, agent_id

    counts = Counter(expected.values())
    assert summary["controls_passing"] == counts["pass"]
    assert summary["controls_failing"] == counts["fail"]
    # M4: error is neither pass, fail nor pending. It used to be counted as
    # pending, which read as "not assessed yet" for a control the engine tried
    # and could not judge. It has its own count, and is in neither of the
    # others -- while staying in total_controls and the posture denominator.
    assert counts["error"] > 0, "this fixture must exercise an errored control"
    assert summary["controls_errored"] == counts["error"]
    assert summary["controls_pending"] == (
        len(expected) - counts["pass"] - counts["fail"] - counts["error"])
    assert summary["posture_score"] == round(counts["pass"] / len(expected), 2)

    assert (policy["totalChecks"], policy["passed"], policy["failed"], policy["errored"]) == (
        len(expected), counts["pass"], counts["fail"], counts["error"])
    frameworks = {f["name"]: f for f in policy["frameworks"]}
    for name, checks in (("CIS Kubernetes Benchmark", CIS), ("FINOS AI Governance Framework", AIGF)):
        per_control = {c: [expected[(a, control_of[c])] for a in WORKLOAD] for c in checks}
        assert frameworks[name]["totalControls"] == len(checks)
        assert frameworks[name]["passedControls"] == sum(all(s == "pass" for s in v) for v in per_control.values())
        assert frameworks[name]["failedControls"] == sum(any(s == "fail" for s in v) for v in per_control.values())

    audit = await seeded_pool.fetchrow(
        """SELECT detail FROM audit_events WHERE event_type = 'compliance.scan_completed'
            ORDER BY timestamp DESC LIMIT 1""")
    detail = json.loads(audit["detail"])
    new = Counter(expected[(a, control_of[c])] for a in WORKLOAD for c in CIS + AIGF)
    assert (detail["controls_assessed"], detail["controls_passed"], detail["controls_failed"],
            detail["controls_errored"], detail["controls_no_workload"], detail["agents_scanned"]) == (
        5 * (len(CIS) + len(AIGF)), new["pass"], new["fail"], new["error"], 2 * len(CIS), 5)
    # No assessment time on a control nobody assessed.
    unassessed = await seeded_pool.fetch(
        "SELECT assessed_at FROM agent_compliance_results WHERE agent_id = ANY($1::uuid[]) AND control_id = ANY($2::uuid[])",
        [PATSY, ROBIN], [control_of[c] for c in CIS])
    assert len(unassessed) == 2 * len(CIS) and all(r["assessed_at"] is None for r in unassessed)


@pytest.mark.asyncio
async def test_a_stale_scan_never_overwrites_a_fresher_scans_verdict(seeded_pool, monkeypatch):
    """H3: two scans of one tenant, interleaved.

    The first scan reads the registry, then its engine call hangs; the second
    scan runs to completion while it hangs; only then does the first scan get
    its answer and write.  Its view of the agent is the older one, so the row
    must keep the second scan's verdict.  The upsert is guarded on freshness
    and the write transaction holds a per-tenant advisory lock, so the loser
    neither interleaves row by row nor lands last-write-wins.
    """
    await _as_tenant_demo(seeded_pool, monkeypatch)
    await seeded_pool.execute(
        "UPDATE agent_registry SET workload_spec = $2::jsonb WHERE id = $1",
        LANCELOT, json.dumps(pod("lancelot")))
    check = "no-privileged-containers"
    control = await seeded_pool.fetchval(
        "SELECT id FROM governance_controls WHERE tenant_id = $1 AND policy_check_id = $2",
        TENANT, check)

    stale_at_engine = asyncio.Event()
    fresh_committed = asyncio.Event()

    async def engine(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        if body["namespace"] == "stale":
            stale_at_engine.set()
            await asyncio.wait_for(fresh_committed.wait(), timeout=30)
            status = "pass"
        else:
            status = "fail"
        return httpx.Response(200, json=[{
            "framework": "cis-kubernetes", "controlSet": "set", "control": check, "check": check,
            "passed": status == "pass", "status": status, "policyVersion": "v1.8.0",
            "ale": 0.0, "var95": 0.0, "tvar": 0.0, "carriedGbp": 0.0,
            "scanTimestamp": "2026-10-10T12:00:00Z", "calibrationSource": "industry-indicative",
        }])

    async def run(namespace: str) -> dict[str, Any]:
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            resp = await client.post(
                "/api/compliance/policy/scan",
                json={"namespace": namespace, "policyVersion": "v1.8.0",
                      "frameworks": ["cis-kubernetes"], "agentIds": [str(LANCELOT)]},
                headers=eap_bearer(SUBJECT),
            )
            assert resp.status_code == 200, resp.text
            return resp.json()

    with respx.mock(assert_all_called=True) as mock:
        mock.post(ENGINE).mock(side_effect=engine)
        stale = asyncio.create_task(run("stale"))
        # The loser must have taken its view of the registry FIRST.
        await asyncio.wait_for(stale_at_engine.wait(), timeout=30)
        fresh = await run("fresh")
        fresh_committed.set()
        stale_body = await stale

    # Each scan reports what its own engine call said -- neither response lies.
    assert [c["status"] for c in fresh["checks"]] == ["fail"]
    assert [c["status"] for c in stale_body["checks"]] == ["pass"]
    # The row keeps the fresher assessment.
    row = await seeded_pool.fetchrow(
        "SELECT status FROM agent_compliance_results WHERE agent_id = $1 AND control_id = $2",
        LANCELOT, control)
    assert row["status"] == "fail"


TENANT_B = "tenant-b-f3"
TENANT_B_FRAMEWORK = uuid.UUID("fb000000-0000-0000-0000-000000000001")


async def _as_tenant_demo(seeded_pool, monkeypatch):
    async def get_pool():
        return seeded_pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    monkeypatch.setattr(settings, "api_subject_tenants", {**settings.api_subject_tenants, SUBJECT: TENANT})


@pytest.mark.asyncio
async def test_another_tenants_identically_named_framework_never_reaches_this_tenant(seeded_pool, monkeypatch):
    """H4: the framework catalogue and its policy summary are tenant-scoped.

    Tenant B activates a framework with exactly the name tenant-demo's CIS pack
    carries, a different control count and a control of its own.  Grouping by
    name used to merge the two; reading without a tenant filter used to list B's.
    """
    await _as_tenant_demo(seeded_pool, monkeypatch)
    await seeded_pool.execute(
        """INSERT INTO governance_frameworks (id, tenant_id, name, version, regulatory_body, control_count, activated_by)
           VALUES ($1, $2, 'CIS Kubernetes Benchmark', 'b-only', 'Tenant B', 99, 'b@example.test')""",
        TENANT_B_FRAMEWORK, TENANT_B)
    await seeded_pool.execute(
        """INSERT INTO governance_controls (id, tenant_id, framework_id, name, description, control_order)
           VALUES ('cb000000-0000-0000-0000-000000000001', $1, $2, 'B secret control', 'b', 1)""",
        TENANT_B, TENANT_B_FRAMEWORK)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        catalogue = (await client.get("/api/compliance/frameworks", headers=eap_bearer(SUBJECT))).json()
        summaries = (await client.get("/api/compliance/policy/frameworks", headers=eap_bearer(SUBJECT))).json()

    assert str(TENANT_B_FRAMEWORK) not in {f["id"] for f in catalogue}
    assert "B secret control" not in {c["name"] for f in catalogue for c in f["controls"]}
    assert "b-only" not in {f["version"] for f in catalogue}
    names = [f["name"] for f in summaries]
    assert len(names) == len(set(names)), names
    [cis] = [f for f in summaries if f["name"] == "CIS Kubernetes Benchmark"]
    assert cis["totalControls"] == len(CIS)
    assert "b-only" not in cis["versions"]
