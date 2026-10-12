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


#: The seeded agents that get a recorded workload, and the one that gets none.
#: An agent with no observed workload is the H1 path: a pack whose checks read
#: only ``object`` is not asked about it at all, so its mapped controls come
#: back not-evaluated with reason ``no_workload`` -- and it must be reported as
#: that, not as a failed agent and not as 17 failing CIS controls.
WITH_WORKLOAD = AGENTS[:4]
NO_WORKLOAD_AGENT = AGENTS[4]


def _check_versions() -> dict[tuple[str, str], set[str]]:
    """(pack id, check id) -> every pack version that defines that check.

    Used to assert the fe asked the engine at a version that actually carries
    the check.  The fe groups its calls by each pack's own activated version
    and treats the caller's ``policyVersion`` as a fallback, so nothing in the
    request pins the version a verdict was computed at -- only the pack files
    say which versions are even possible.
    """
    out: dict[tuple[str, str], set[str]] = {}
    for path in sorted(POLICY_ROOT.glob("frameworks/*/*/framework.json")):
        pack = json.loads(path.read_text(encoding="utf-8"))
        for control_set in pack["controlSets"]:
            for control in control_set["controls"]:
                for check in control["checks"]:
                    out.setdefault((pack["id"], check["id"]), set()).add(pack["version"])
    return out


def _plan() -> list[dict[str, Any]]:
    """One seeded agent per row: its object, its agent context, its expectations.

    Every agent with a workload gets a DIFFERENT (CIS fixture, AIGF fixture)
    pair, and the assignment is rejected outright if two agents end up
    expecting the same verdict vector.  Under the previous
    ``CIS[i % n], AIGF[i % m]`` the fixture lists wrapped at different lengths
    and agents 1 and 5 shared a vector, as did 1 and 4 -- so a verdict landing
    on the wrong agent, the single defect the per-agent scan exists to prevent,
    was invisible to this test for those pairs.
    """
    assert CIS_FIXTURES and AIGF_FIXTURES, "no integration fixtures under policy/frameworks"
    assert len(CIS_FIXTURES) >= len(WITH_WORKLOAD) and len(AIGF_FIXTURES) >= len(WITH_WORKLOAD), (
        f"need {len(WITH_WORKLOAD)} distinct fixtures per pack, have "
        f"{len(CIS_FIXTURES)} CIS and {len(AIGF_FIXTURES)} AIGF"
    )
    plan: list[dict[str, Any]] = []
    for i, agent_id in enumerate(WITH_WORKLOAD):
        cis, aigf = CIS_FIXTURES[i], AIGF_FIXTURES[i]
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
    # The no-workload agent reuses an AIGF context -- there are only as many
    # AIGF fixtures as agents with workloads -- but it expects NO cis-kubernetes
    # verdict at all, so its vector is still unique and a verdict mixed up with
    # it is still visible on the CIS side.
    aigf = AIGF_FIXTURES[-1]
    plan.append({
        "agent_id": NO_WORKLOAD_AGENT,
        "object": None,
        "context": aigf["input"]["agent"],
        "expect": {("finos-aigf", k): v for k, v in aigf["expect"].items()},
        "fixtures": ("<no workload>", aigf["name"]),
    })

    seen: dict[tuple[Any, ...], tuple[str, str]] = {}
    for row in plan:
        vector = tuple(sorted((f, c, v) for (f, c), v in row["expect"].items()))
        clash = seen.get(vector)
        assert clash is None, (
            f"{row['fixtures']} and {clash} expect identical verdicts across every "
            "control: a verdict landing on the wrong agent would be invisible"
        )
        seen[vector] = row["fixtures"]
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
             "POLICY_BUNDLES_DIR": str(POLICY_ROOT / "bundles"), "POLICY_API_KEYS": "",
             # SIGNAL_SEGMENT_PSEUDONYM_KEY became REQUIRED, not optional, when
             # the SLAWS merge added policy/bundles/kusari-cloud-signals, which
             # declares actor_vars. pkg/obscel then refuses to load the bundle
             # without a key and the engine exits rather than start -- so this
             # test failed with "policy-engine did not come up (rc=1)", which
             # names the symptom and not the cause.
             #
             # The refusal is correct and must not be worked around: processing
             # actor data with no pseudonymisation key is the failure the key
             # exists to prevent, and a bundle silently skipped would be worse
             # than a refusal to start.
             #
             # This value is deliberately recognisable as a test fixture rather
             # than a plausible secret, while still being exactly 32 bytes of
             # hex: "e2" repeated 32 times. Production keys are minted by
             # scripts/signal-segment-key.sh into a Secret; nothing here should
             # ever be copied there.
             #
             # The length is load-bearing and the error message does not say so.
             # A 62-character key is rejected with the SAME text as no key at
             # all -- "declares actor_vars but SIGNAL_SEGMENT_PSEUDONYM_KEY is
             # not configured" -- while the evaluator had already logged
             # "pseudonymisation key configured for policy evaluation" for that
             # very key. So a wrong-length key reads as a missing one, and two
             # log lines in the same startup appear to contradict each other.
             # Reported as a finding; the 64 characters here are what actually
             # makes the engine start.
             "SIGNAL_SEGMENT_PSEUDONYM_KEY": "e2" * 32},
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
            row["agent_id"],
            json.dumps(row["object"]) if row["object"] is not None else None,
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

    # Nothing BEYOND the expectations either: a check the fixtures say nothing
    # about is a verdict nobody has pinned, and an extra pack reaching an agent
    # would otherwise pass unremarked.
    for row in plan:
        got_keys = {(c["framework"], c["check"]) for c in scan_body["checks"]
                    if c["agentId"] == str(row["agent_id"])}
        extra = sorted(got_keys - set(row["expect"]))
        if extra:
            mismatches.append(("unexpected-checks", row["fixtures"], extra, None, None, None))

    # Every verdict was computed at a version that actually defines its check.
    # The fe asks each pack at its own activated version and uses the caller's
    # policyVersion only as a fallback, so this is the only thing that says the
    # version a verdict is attributed to is a version that could produce it.
    allowed_versions = _check_versions()
    for check in scan_body["checks"]:
        allowed = allowed_versions.get((check["framework"], check["check"]))
        if not allowed or check["policyVersion"] not in allowed:
            mismatches.append(("version", check["framework"], check["check"],
                               check["policyVersion"], sorted(allowed or ()), None))

    # ---- the agent with no observed workload (H1) -------------------------------
    assert scan_body["agentsNotFound"] == []
    no_workload = [g for g in scan_body["controlGaps"] if g["agentId"] == str(NO_WORKLOAD_AGENT)]
    assert no_workload, "the agent with no workload must be reported, not silently skipped"
    assert {g["reason"] for g in no_workload} == {"no_workload"}
    assert {g["stored"] for g in no_workload} == {"pending"}
    assert {g["framework"] for g in no_workload} == {"cis-kubernetes"}
    # It is not a failed agent: its AIGF checks were assessed normally.
    assert str(NO_WORKLOAD_AGENT) not in scan_body["agentsFailed"]
    assert {c["framework"] for c in scan_body["checks"]
            if c["agentId"] == str(NO_WORKLOAD_AGENT)} == {"finos-aigf"}

    # ---- the scan's own framework summaries, measured against its own rows ------
    scan_frameworks = {f["id"]: f for f in scan_body["summary"]["frameworks"]}
    for pack in ("cis-kubernetes", "finos-aigf"):
        rows = [c for c in scan_body["checks"] if c["framework"] == pack]
        assert rows, pack
        assert scan_frameworks[pack]["totalResults"] == len(rows), pack
        assert scan_frameworks[pack]["totalControls"] == len({
            c["controlId"] or (c["controlSet"], c["control"], c["check"]) for c in rows}), pack
        # A control counted once however many agents assessed it: the row count
        # is strictly larger here, which is what totalControls used to report.
        assert scan_frameworks[pack]["totalControls"] < scan_frameworks[pack]["totalResults"], pack

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

    # The no-workload agent's CIS controls: pending, never a verdict about a
    # workload nobody observed.
    for (framework, check), control in control_of.items():
        if framework != "cis-kubernetes":
            continue
        got = by_agent[str(NO_WORKLOAD_AGENT)].get(control)
        if got != "pending":
            mismatches.append(("no-workload-posture", "<no workload>", framework, check, "pending", got))
    assert mismatches == [], f"{len(mismatches)} mismatches:\n" + "\n".join(map(str, mismatches))

    # ---- /compliance/policy/summary: per framework, across the five agents ------
    frameworks = {f["name"]: f for f in policy["frameworks"]}
    for name, pack in (("CIS Kubernetes Benchmark", "cis-kubernetes"),
                       ("FINOS AI Governance Framework", "finos-aigf")):
        # Measured from the scan rather than compared against the seeded
        # control_count: the catalogue's own count proving it equals itself
        # said nothing about whether the scan reached every control.
        assessed = {c["controlId"] for c in scan_body["checks"]
                    if c["framework"] == pack and c["controlId"]}
        assert frameworks[name]["totalControls"] == len(assessed), name
        # Stored status per control, across every agent that has a row for it --
        # which for cis-kubernetes includes the no-workload agent's pending ones.
        per_control: dict[str, list[str]] = {}
        for (framework, check), control in control_of.items():
            if framework != pack:
                continue
            per_control[check] = [
                by_agent[str(row["agent_id"])].get(control) for row in plan
                if by_agent[str(row["agent_id"])].get(control) is not None
            ]
        assert frameworks[name]["passedControls"] == sum(
            bool(v) and all(s == "pass" for s in v) for v in per_control.values()), name
        assert frameworks[name]["failedControls"] == sum(
            any(s == "fail" for s in v) for v in per_control.values()), name
    stored_now = [status for agent in by_agent.values() for status in agent.values()]
    assert policy["errored"] == stored_now.count("error")
