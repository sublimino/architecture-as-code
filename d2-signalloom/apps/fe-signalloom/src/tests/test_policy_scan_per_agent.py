"""Per-agent policy scan: subject assembly, verdict mapping, reconciliation.

Tier 1 (no database, engine mocked with respx).  The real-Postgres twin is
``test_policy_scan_integration.py``; the real-engine e2e is
``test/cel-frameworks-api-e2e.py`` at the repository root.

What these tests pin, and the defect each one would catch:

* the body POSTed to the engine is built from THIS agent's registry row --
  its pod-shaped workload and its governance context -- and nothing else
  (the defect: one hardcoded, non-Pod manifest for every scan);
* every verdict lands on exactly the (agent, control) it was computed for
  (the defect: ``UPDATE ... WHERE c.name = $3 OR c.id::text = $4`` stamped
  one verdict on every agent's row);
* ``status`` from the engine is authoritative, ``error`` is stored as
  ``error`` and is neither a pass nor a fail;
* with the engine unreachable nothing changes and nothing is invented (the
  defect: a DB "fallback" that reported unassessed controls as passed).
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient

import api_compat
from config import settings
from conftest import EAP_ALICE, EAP_TENANT_A, EAP_TENANT_B, eap_bearer
from main import app
from policy_scan import build_agent_object, build_agent_policy_context

EAP_AUTHENTICATED = True

ENGINE = f"{getattr(settings, 'policy_engine_url', 'http://policy-engine:8081')}/api/v1/compliance/scan"

AGENT_A = uuid.UUID("aaaaaaaa-0000-0000-0000-000000000001")
AGENT_B = uuid.UUID("aaaaaaaa-0000-0000-0000-000000000002")
AGENT_C = uuid.UUID("aaaaaaaa-0000-0000-0000-000000000003")

CTRL_PRIV = uuid.UUID("cccccccc-0000-0000-0000-000000000001")
CTRL_ROOT = uuid.UUID("cccccccc-0000-0000-0000-000000000002")
CTRL_MODEL = uuid.UUID("cccccccc-0000-0000-0000-000000000003")
CTRL_PI = uuid.UUID("cccccccc-0000-0000-0000-000000000004")

POD_A = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {"name": "agent-a", "namespace": "agents"},
    "spec": {
        "automountServiceAccountToken": False,
        "containers": [
            {"name": "runtime", "image": "ghcr.io/x/a:1", "securityContext": {"privileged": True}},
        ],
    },
}

DEPLOYMENT = {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": {"name": "agent-d", "namespace": "agents"},
    "spec": {
        "template": {
            "metadata": {"labels": {"app": "d"}},
            "spec": {"containers": [{"name": "c", "image": "i"}]},
        },
    },
}


# --------------------------------------------------------------------------
# A fake database that understands exactly the statements the scan issues.
# --------------------------------------------------------------------------

class FakeDB:
    def __init__(self, agents: list[dict[str, Any]], controls: list[dict[str, Any]]):
        self.agents = agents
        self.controls = controls
        #: (agent_id, control_id) -> {"status", "evidence_ref", "tenant_id"}
        self.results: dict[tuple[uuid.UUID, uuid.UUID], dict[str, Any]] = {}
        self.audit: list[dict[str, Any]] = []
        self.result_writes = 0
        #: (agent_id, control_id) -> the assessed_at the last write stored
        self.assessed: dict[tuple[uuid.UUID, uuid.UUID], Any] = {}
        #: Every statement the write transaction issued, in order.
        self.statements: list[tuple[Any, ...]] = []

    # -- connection protocol --------------------------------------------
    def acquire(self):
        return self

    def transaction(self):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
        # Both statements are ``WHERE tenant_id = $1``. The fake has to honour
        # that, or a tenant-isolation test here is theatre: it would be asserting
        # that rows the fake never withheld did not come back.
        if "FROM agent_registry" in query:
            wanted = set(args[1])
            return [a for a in self.agents
                    if a["tenant_id"] == args[0] and (not wanted or str(a["id"]) in wanted)]
        if "FROM governance_controls" in query:
            wanted = set(args[1])
            return [c for c in self.controls
                    if c["tenant_id"] == args[0]
                    and (not wanted or c["policy_framework_id"] in wanted)]
        raise AssertionError(f"unexpected fetch: {query}")

    async def execute(self, query: str, *args: Any) -> str:
        if "pg_advisory_xact_lock" in query:
            self.statements.append(("lock", args[0]))
            return "SELECT 1"
        if "INSERT INTO agent_compliance_results" in query:
            self.statements.append(("result", args[1], args[2]))
            tenant, agent_id, control_id, status, evidence = args[:5]
            self.results[(agent_id, control_id)] = {
                "tenant_id": tenant, "status": status, "evidence_ref": evidence,
            }
            # The statement's own assessed_at value: the bound parameter when it
            # passes one, else the SQL text's (e.g. now()).
            self.assessed[(agent_id, control_id)] = args[5] if len(args) > 5 else "sql:now()"
            self.result_writes += 1
            return "INSERT 0 1"
        if "INSERT INTO audit_events" in query:
            self.statements.append(("audit", args[1]))
            self.audit.append({"event_type": args[1], "detail": json.loads(args[5])})
            return "INSERT 0 1"
        raise AssertionError(f"unexpected execute: {query}")


def agent_row(agent_id, name, *, model_approved=None, context=None, workload=None,
              tenant=EAP_TENANT_A):
    return {
        "id": agent_id,
        "name": name,
        "tenant_id": tenant,
        "model_approved": model_approved,
        # asyncpg returns json/jsonb as text without a codec; the builder must cope.
        "policy_context": json.dumps(context) if context is not None else None,
        "workload_spec": json.dumps(workload) if workload is not None else None,
    }


#: The pack version each tenant framework is activated at (governance_frameworks.version).
PACK_VERSION = {"cis-kubernetes": "v1.8.0", "finos-aigf": "v1.0.0"}


def control(control_id, framework, check, tenant=EAP_TENANT_A):
    return {"control_id": control_id, "policy_framework_id": framework, "policy_check_id": check,
            "framework_version": PACK_VERSION[framework], "tenant_id": tenant}


def answering(results):
    """Engine stand-in: answer each call with the results for the packs it asked
    about, at the version it asked about.

    The version half matters.  The real engine evaluates only the checks its
    ``policyVersion`` selects and answers ``400 no_checks_for_framework``
    otherwise, so a mock that filtered on the framework alone would answer a
    scan that asked every pack at one arbitrary version -- and the test suite
    would pass with the per-pack version lookup deleted.
    """
    def respond(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        asked, version = body["frameworks"], body["policyVersion"]
        return httpx.Response(200, json=[
            r for r in results
            if r["framework"] in asked and r.get("policyVersion") == version
        ])
    return respond


CONTROLS = [
    control(CTRL_PRIV, "cis-kubernetes", "no-privileged-containers"),
    control(CTRL_ROOT, "cis-kubernetes", "no-root-containers"),
    control(CTRL_MODEL, "finos-aigf", "registered-model-registry-entry"),
    control(CTRL_PI, "finos-aigf", "prompt-injection-guardrail-active"),
]


def _every_check_passes():
    return [item(c["policy_framework_id"], c["policy_check_id"], "pass") for c in CONTROLS]


def item(framework, check, status=None, *, passed=None, error=None):
    out: dict[str, Any] = {
        "framework": framework,
        "controlSet": "set",
        "control": f"{framework}/{check} control",
        "check": check,
        "policyVersion": PACK_VERSION.get(framework, "v1.0.0"),
        "ale": 100.0,
        "var95": 200.0,
        "tvar": 300.0,
        "carriedGbp": 50.0,
        "scanTimestamp": "2026-10-10T12:00:00Z",
        "calibrationSource": "industry-indicative",
    }
    if status is not None:
        out["status"] = status
        out["passed"] = status == "pass"
        out["checkName"] = check
        out["controlId"] = f"{framework}:{check}"
        out["frameworkVersion"] = PACK_VERSION.get(framework, "v1.0.0")
    if passed is not None:
        out["passed"] = passed
    if error is not None:
        out["error"] = error
    return out


#: An engine answer covering every mapped check (H2: a partial answer is a gap).
EVERY_CHECK_PASSES = _every_check_passes()


@pytest.fixture
def db(monkeypatch):
    holder: dict[str, FakeDB] = {}

    def install(fake: FakeDB) -> FakeDB:
        async def get_pool():
            return fake

        monkeypatch.setattr(api_compat, "_get_pool", get_pool)
        holder["db"] = fake
        return fake

    return install


async def scan(body: dict[str, Any]) -> httpx.Response:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        return await client.post("/api/compliance/policy/scan", json=body, headers=eap_bearer(EAP_ALICE))


SCAN = {"namespace": "agents", "policyVersion": "v1.0.0", "frameworks": []}


# --------------------------------------------------------------------------
# Pure builders
# --------------------------------------------------------------------------

def test_context_maps_columns_and_declared_facts_and_never_defaults():
    row = agent_row(
        AGENT_A, "a", model_approved=False,
        context={"registry": {"model_registered": True}, "guardrails": {"prompt_injection_filter": True}},
    )
    # The column is the system of record: a declared "registered" cannot
    # override a registry row that says the model is not approved.
    assert build_agent_policy_context(row) == {
        "registry": {"model_registered": False},
        "guardrails": {"prompt_injection_filter": True},
    }
    # NULL column, no declaration: the fact is absent, not False and not True.
    assert build_agent_policy_context(agent_row(AGENT_B, "b")) == {}
    # NULL column keeps a declared fact.
    assert build_agent_policy_context(
        agent_row(AGENT_B, "b", context={"registry": {"model_registered": True}})
    ) == {"registry": {"model_registered": True}}


def test_object_is_the_pod_or_the_pod_template_and_none_when_absent():
    assert build_agent_object(agent_row(AGENT_A, "a", workload=POD_A)) == POD_A
    assert build_agent_object(agent_row(AGENT_A, "a", workload=DEPLOYMENT)) == {
        # no-default-namespace reads object.metadata.namespace: the workload's
        # namespace travels with its pod template.
        "metadata": {"labels": {"app": "d"}, "namespace": "agents"},
        "spec": {"containers": [{"name": "c", "image": "i"}]},
    }
    assert build_agent_object(agent_row(AGENT_A, "a")) is None
    # Not pod-shaped: no spec. Sending it would let pod checks judge nothing.
    assert build_agent_object(agent_row(AGENT_A, "a", workload={"containers": []})) is None
    cron = {"kind": "CronJob", "metadata": {"namespace": "agents"},
            "spec": {"jobTemplate": {"spec": {"template": {"spec": {"containers": [{"name": "c"}]}}}}}}
    assert build_agent_object(agent_row(AGENT_A, "a", workload=cron)) == {
        "metadata": {"namespace": "agents"}, "spec": {"containers": [{"name": "c"}]}}


@pytest.mark.parametrize("workload", [
    # H1: a spec with no non-empty containers list is not a workload the CIS
    # checks can judge; sent as one, most checks PASS vacuously.
    {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "svc"},
     "spec": {"ports": [{"port": 80}], "selector": {"app": "a"}}},
    {"spec": {}},
    {"kind": "Pod", "spec": {}},
    {"kind": "Pod", "spec": {"containers": []}},
    {"kind": "Pod", "spec": {"containers": "runtime"}},
    # A pod spec with no kind is not known to be a Pod.
    {"spec": {"containers": [{"name": "c"}]}},
    {"kind": "ConfigMap", "spec": {"containers": [{"name": "c"}]}},
    {"kind": "Deployment", "spec": {"template": {"spec": {}}}},
    {"kind": "Deployment", "spec": {"template": {"spec": {"containers": []}}}},
    {"kind": "Deployment", "spec": {"containers": [{"name": "c"}]}},
    {"kind": "CronJob", "spec": {"jobTemplate": {"spec": {"template": {"spec": {}}}}}},
])
def test_object_is_none_unless_a_pod_or_controller_with_containers(workload):
    assert build_agent_object(agent_row(AGENT_A, "a", workload=workload)) is None


@pytest.mark.parametrize("kind", ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"])
def test_every_controller_kind_yields_its_pod_template(kind):
    workload = {"kind": kind, "metadata": {"namespace": "agents"},
                "spec": {"template": {"spec": {"containers": [{"name": "c"}]}}}}
    assert build_agent_object(agent_row(AGENT_A, "a", workload=workload)) == {
        "metadata": {"namespace": "agents"}, "spec": {"containers": [{"name": "c"}]}}


def test_object_only_packs_are_exactly_the_repo_pack_versions_that_read_only_object():
    """The H1 rule: with no workload, a pack version is not sent when none of its
    checks reads ``agent`` or ``request`` (so every evaluated check reads only
    ``object``).  The fe image has no ``policy/``, so the set is a constant and
    this derives it from the packs in the checkout."""
    import re
    from pathlib import Path

    from policy_scan import OBJECT_ONLY_PACKS

    packs = Path(__file__).resolve().parents[5] / "policy" / "frameworks"
    derived = set()
    for path in packs.glob("*/*/framework.json"):
        pack = json.loads(path.read_text(encoding="utf-8"))
        expressions = [check.get("celExpression", "") for cs in pack["controlSets"]
                       for control in cs["controls"] for check in control["checks"]]
        reads = {var for expr in expressions for var in ("object", "agent", "request")
                 if re.search(rf"\b{var}\.", expr)}
        if reads == {"object"}:
            derived.add((pack["id"], pack["version"]))
    assert ("cis-kubernetes", "v1.8.0") in derived
    assert OBJECT_ONLY_PACKS == frozenset(derived)


# --------------------------------------------------------------------------
# The engine sees each agent's own subject
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_request_body_per_agent_is_that_agents_context_and_object(db):
    fake = db(FakeDB(
        agents=[
            agent_row(AGENT_A, "agent-a", model_approved=True, context={"guardrails": {"prompt_injection_filter": True}}, workload=POD_A),
            agent_row(AGENT_B, "agent-b"),
        ],
        controls=CONTROLS,
    ))
    with respx.mock(assert_all_called=True) as mock:
        route = mock.post(ENGINE).mock(side_effect=answering(EVERY_CHECK_PASSES))
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    bodies = [json.loads(call.request.content) for call in route.calls]
    context_a = {"registry": {"model_registered": True}, "guardrails": {"prompt_injection_filter": True}}
    # One call per pack version: the engine filters checks by policyVersion and
    # the two packs are activated at different versions.
    assert bodies == [
        {"namespace": "agents", "policyVersion": "v1.8.0", "frameworks": ["cis-kubernetes"],
         "object": POD_A, "agent": context_a, "request": {}},
        {"namespace": "agents", "policyVersion": "v1.0.0", "frameworks": ["finos-aigf"],
         "object": POD_A, "agent": context_a, "request": {}},
        # H1: no workload on record. The engine binds an absent object to {}
        # and every CIS check FAILS on {}, so cis-kubernetes is not asked at all.
        {"namespace": "agents", "policyVersion": "v1.0.0", "frameworks": ["finos-aigf"],
         "agent": {}, "request": {}},
    ]
    for call in route.calls:
        assert call.request.headers["X-Tenant-ID"] == EAP_TENANT_A


# --------------------------------------------------------------------------
# Verdict mapping
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_status_is_authoritative_and_error_is_stored_as_error(db):
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=CONTROLS))
    engine_results = [
        item("cis-kubernetes", "no-privileged-containers", "fail"),
        # Older engine: no status, fall back to passed.
        item("cis-kubernetes", "no-root-containers", passed=True),
        item("finos-aigf", "registered-model-registry-entry", "error", error="no such key: registry"),
        # A status the contract does not define is not a pass.
        item("finos-aigf", "prompt-injection-guardrail-active", "maybe"),
    ]
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(engine_results))
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    assert fake.results == {
        (AGENT_A, CTRL_PRIV): {"tenant_id": EAP_TENANT_A, "status": "fail",
                               "evidence_ref": "policy-engine:cis-kubernetes/no-privileged-containers@v1.8.0"},
        (AGENT_A, CTRL_ROOT): {"tenant_id": EAP_TENANT_A, "status": "pass",
                               "evidence_ref": "policy-engine:cis-kubernetes/no-root-containers@v1.8.0"},
        (AGENT_A, CTRL_MODEL): {"tenant_id": EAP_TENANT_A, "status": "error",
                                "evidence_ref": "policy-engine:finos-aigf/registered-model-registry-entry@v1.0.0"},
        (AGENT_A, CTRL_PI): {"tenant_id": EAP_TENANT_A, "status": "error",
                             "evidence_ref": "policy-engine:finos-aigf/prompt-injection-guardrail-active@v1.0.0"},
    }
    data = resp.json()
    assert data["engineInvoked"] is True
    assert [(c["agentId"], c["check"], c["status"], c["passed"], c["controlId"]) for c in data["checks"]] == [
        (str(AGENT_A), "no-privileged-containers", "fail", False, str(CTRL_PRIV)),
        (str(AGENT_A), "no-root-containers", "pass", True, str(CTRL_ROOT)),
        (str(AGENT_A), "registered-model-registry-entry", "error", False, str(CTRL_MODEL)),
        (str(AGENT_A), "prompt-injection-guardrail-active", "error", False, str(CTRL_PI)),
    ]
    assert data["checks"][2]["error"] == "no such key: registry"
    assert (data["summary"]["totalChecks"], data["summary"]["passed"],
            data["summary"]["failed"], data["summary"]["errored"]) == (4, 1, 1, 2)
    [audit] = fake.audit
    assert audit["event_type"] == "compliance.scan_completed"
    detail = audit["detail"]
    assert (detail["controls_assessed"], detail["controls_passed"], detail["controls_failed"],
            detail["controls_errored"], detail["checks_unmapped"], detail["agents_scanned"],
            detail["agents_failed"], detail["engine_invoked"]) == (4, 1, 1, 2, 0, 1, 0, True)


@pytest.mark.asyncio
async def test_not_evaluated_is_carried_through_and_stored_as_pending(db):
    """A placeholder check is not assessed: neither a pass nor a fail."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0], CONTROLS[1]]))
    fake.results[(AGENT_A, CTRL_ROOT)] = {"tenant_id": EAP_TENANT_A, "status": "pass", "evidence_ref": "old"}
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([
            item("cis-kubernetes", "no-root-containers", "not_evaluated"),
            item("cis-kubernetes", "no-privileged-containers", "pass"),
        ]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert fake.results[(AGENT_A, CTRL_ROOT)]["status"] == "pending"
    assert fake.results[(AGENT_A, CTRL_PRIV)]["status"] == "pass"
    # L5: pending is not an assessment, so it carries no assessed_at; the
    # pass that was assessed in this scan does.
    assert fake.assessed[(AGENT_A, CTRL_ROOT)] is None
    assert fake.assessed[(AGENT_A, CTRL_PRIV)] is not None
    data = resp.json()
    assert [(c["check"], c["status"], c["passed"]) for c in data["checks"]] == [
        ("no-root-containers", "not_evaluated", False),
        ("no-privileged-containers", "pass", True),
    ]
    assert (data["summary"]["passed"], data["summary"]["failed"], data["summary"]["errored"],
            data["summary"]["notEvaluated"]) == (1, 0, 0, 1)
    detail = fake.audit[0]["detail"]
    assert (detail["controls_passed"], detail["controls_failed"], detail["controls_not_evaluated"]) == (1, 0, 1)


@pytest.mark.asyncio
@pytest.mark.parametrize("status,body", [
    (400, {"error": "no_checks_for_framework", "framework": "finos-aigf"}),
    (500, {"error": "pack failed to load"}),
])
async def test_engine_refusal_for_one_pack_is_a_failed_agent_not_an_empty_pass(db, status, body):
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=CONTROLS))

    def refuse_aigf(request: httpx.Request) -> httpx.Response:
        if json.loads(request.content)["frameworks"] == ["finos-aigf"]:
            return httpx.Response(status, json=body)
        return answering([item("cis-kubernetes", "no-privileged-containers", "pass")])(request)

    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=refuse_aigf)
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert (data["engineInvoked"], data["checks"], data["agentsFailed"]) == (False, [], [str(AGENT_A)])
    assert fake.results == {}


@pytest.mark.asyncio
async def test_engine_money_in_pence_is_reported_in_whole_pounds(db):
    """The engine rounds FAIR figures to the penny; these response fields are
    integer pounds. A fractional figure used to fail validation (HTTP 500) on
    every real scan."""
    db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[1]]))
    result = item("cis-kubernetes", "no-root-containers", "fail")
    result.update({"ale": 59860.07, "var95": 133551.5, "tvar": 159991.96, "carriedGbp": 175991.15})
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([result]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    [check] = resp.json()["checks"]
    assert (check["ale"], check["var95"], check["tvar"], check["carriedGbp"]) == (59860, 133552, 159992, 175991)
    assert check["carried"] == {"amount": 175991, "currency": "GBP"}


@pytest.mark.asyncio
async def test_unmapped_checks_are_reported_but_never_stored(db):
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[]))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([
            item("finos-aigf", "a-check-with-no-seed-row", "pass"),
        ]))
        resp = await scan({**SCAN, "frameworks": ["finos-aigf"]})
    assert resp.status_code == 200, resp.text
    assert fake.results == {}
    [check] = resp.json()["checks"]
    assert (check["status"], check["controlId"]) == ("pass", None)
    assert fake.audit[0]["detail"]["checks_unmapped"] == 1
    assert fake.audit[0]["detail"]["controls_assessed"] == 0


# --------------------------------------------------------------------------
# Another tenant's agents (L1)
# --------------------------------------------------------------------------

FOREIGN_AGENT = uuid.UUID("bbbbbbbb-0000-0000-0000-000000000001")


@pytest.mark.asyncio
async def test_a_scan_of_another_tenants_agents_scans_and_writes_nothing(db):
    """L1: ``agentIds`` is caller-supplied, and the registry read is the only
    thing standing between it and another tenant's agents.  Naming one scans
    nothing, writes nothing, and asks the engine nothing -- the id is simply
    not an agent as far as this caller is concerned."""
    fake = db(FakeDB(
        agents=[agent_row(AGENT_A, "agent-a", workload=POD_A),
                agent_row(FOREIGN_AGENT, "tenant-b-agent", workload=POD_A, tenant=EAP_TENANT_B)],
        controls=CONTROLS + [control(uuid.UUID("cccccccc-0000-0000-0000-00000000000b"),
                                     "cis-kubernetes", "no-privileged-containers",
                                     tenant=EAP_TENANT_B)],
    ))
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(ENGINE).mock(side_effect=answering(EVERY_CHECK_PASSES))
        resp = await scan({**SCAN, "agentIds": [str(FOREIGN_AGENT)]})

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert not route.called
    assert (data["checks"], data["agentsScanned"], data["agentsFailed"],
            data["engineInvoked"]) == ([], 0, [], False)
    assert fake.results == {} and fake.result_writes == 0
    detail = fake.audit[0]["detail"]
    assert (detail["agents_scanned"], detail["controls_assessed"]) == (0, 0)
    # L2: and the response says which ids it found no agent for.
    assert data["agentsNotFound"] == [str(FOREIGN_AGENT)]
    # And the caller's own agent is still scannable, so the filter is a tenant
    # filter and not a broken query.
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(EVERY_CHECK_PASSES))
        resp = await scan({**SCAN, "agentIds": [str(AGENT_A)]})
    assert resp.status_code == 200, resp.text
    assert {c["agentId"] for c in resp.json()["checks"]} == {str(AGENT_A)}
    assert {agent for agent, _ in fake.results} == {AGENT_A}
    assert resp.json()["agentsNotFound"] == []


@pytest.mark.asyncio
async def test_an_agent_id_that_matches_nothing_is_reported_not_a_silent_omission(db):
    """L2: ``agentIds`` entries that match no agent of this tenant used to
    vanish -- the caller asked about four agents, got verdicts for one and no
    statement about the other three.  An id is also matched as a UUID rather
    than as text: ``agent_registry.id::text`` renders lower case, so an id
    typed in upper case matched nothing and the agent silently dropped out of
    its own scan."""
    fake = db(FakeDB(
        agents=[agent_row(AGENT_A, "agent-a", workload=POD_A),
                agent_row(FOREIGN_AGENT, "tenant-b-agent", workload=POD_A, tenant=EAP_TENANT_B)],
        controls=[CONTROLS[0]],
    ))
    unknown = "aaaaaaaa-0000-0000-0000-00000000dead"
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(EVERY_CHECK_PASSES))
        resp = await scan({**SCAN, "agentIds": [
            str(AGENT_A).upper(), unknown, str(FOREIGN_AGENT), "not-a-uuid"]})

    assert resp.status_code == 200, resp.text
    data = resp.json()
    # The upper-case id is the caller's own agent and is scanned.
    assert {c["agentId"] for c in data["checks"]} == {str(AGENT_A)}
    assert data["agentsScanned"] == 1
    # Reported in the order the caller asked, exactly as the caller wrote them.
    assert data["agentsNotFound"] == [unknown, str(FOREIGN_AGENT), "not-a-uuid"]
    assert {agent for agent, _ in fake.results} == {AGENT_A}
    assert fake.audit[0]["detail"]["agents_not_found"] == 3


@pytest.mark.asyncio
async def test_a_scan_of_only_unparseable_ids_scans_no_agent_at_all(db):
    """The id filter is ``cardinality($2) = 0 OR ...``, so dropping every
    unparseable id from the query would turn "scan these three" into "scan the
    whole tenant"."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(ENGINE).mock(side_effect=answering(EVERY_CHECK_PASSES))
        resp = await scan({**SCAN, "agentIds": ["not-a-uuid", "also-not-one"]})
    assert resp.status_code == 200, resp.text
    assert not route.called
    data = resp.json()
    assert (data["checks"], data["agentsScanned"]) == ([], 0)
    assert data["agentsNotFound"] == ["not-a-uuid", "also-not-one"]
    assert fake.result_writes == 0


# --------------------------------------------------------------------------
# Reading the stored verdicts back (M4)
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_an_errored_control_is_reported_as_errored_not_as_pending():
    """M4: ``error`` was folded into ``pending`` by the ``else`` branch, so a
    control the engine tried and could not judge read as "not assessed yet".
    It is now counted on its own.  It stays in the posture denominator: an
    agent the engine could not judge must not score higher for it."""

    class Executor:
        async def fetch(self, query: str, *args: Any) -> list[dict[str, Any]]:
            assert "agent_compliance_results" in query
            return [{"status": "pass", "cnt": 5}, {"status": "fail", "cnt": 2},
                    {"status": "error", "cnt": 2}, {"status": "pending", "cnt": 1}]

    summary = await api_compat._compliance_summary_for_agent(Executor(), AGENT_A)
    assert (summary.total_controls, summary.passing, summary.failing,
            summary.errored, summary.pending) == (10, 5, 2, 2, 1)
    # 5 of 10, not 5 of 8: the two the engine could not judge are still controls
    # this agent is not known to pass.
    assert summary.posture_score == 0.5


# --------------------------------------------------------------------------
# The scan response's per-framework summary (M5)
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_framework_summaries_are_per_framework_and_count_controls_not_rows(db):
    """M5: the scan summary used to group on ``(controlSet, framework)`` and
    then label the row ``id=controlSet, name=framework`` -- so a pack with four
    control sets produced four "frameworks", each named after the pack and
    identified by a control set.  ``totalControls`` was the number of
    agent x check rows, which grows with the fleet: 17 CIS controls scanned
    across 5 agents reported 85 controls.  One row per framework; controls are
    counted once however many agents and checks they were assessed by; the row
    count is reported separately as ``totalResults``."""
    fake = db(FakeDB(
        agents=[agent_row(AGENT_A, "agent-a", workload=POD_A),
                agent_row(AGENT_B, "agent-b", workload=DEPLOYMENT)],
        controls=CONTROLS,
    ))

    def by_agent(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        a = body.get("object", {}).get("metadata", {}).get("name") == "agent-a"
        out = []
        for ctrl in CONTROLS:
            framework, check = ctrl["policy_framework_id"], ctrl["policy_check_id"]
            # Only agent-b fails no-privileged-containers.
            status = "pass" if a or check != "no-privileged-containers" else "fail"
            result = item(framework, check, status)
            # Distinct control sets within one pack must not split the summary.
            result["controlSet"] = f"{framework}-set-{check[:4]}"
            out.append(result)
        # An unmapped check is still one control of its framework.
        out.append(item("finos-aigf", "a-check-with-no-seed-row", "pass"))
        return httpx.Response(200, json=[r for r in out if r["framework"] in body["frameworks"]])

    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=by_agent)
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    summary = resp.json()["summary"]
    frameworks = {f["id"]: f for f in summary["frameworks"]}
    assert sorted(frameworks) == ["cis-kubernetes", "finos-aigf"]
    # A framework is identified and named by its pack id: that is all the engine
    # reports. The human name lives in governance_frameworks.
    assert [f["name"] for f in summary["frameworks"]] == [f["id"] for f in summary["frameworks"]]
    # The versions are the ones the checks were evaluated at, not the request's:
    # each pack is activated at its own version.
    assert frameworks["cis-kubernetes"]["versions"] == ["v1.8.0"]
    assert frameworks["finos-aigf"]["versions"] == ["v1.0.0"]
    # Two agents x two mapped checks = four rows, two controls.
    assert (frameworks["cis-kubernetes"]["totalControls"],
            frameworks["cis-kubernetes"]["totalResults"]) == (2, 4)
    # A control passes only when every row for it passed; agent-b failed one.
    assert (frameworks["cis-kubernetes"]["passedControls"],
            frameworks["cis-kubernetes"]["failedControls"]) == (1, 1)
    # Two mapped checks plus the unmapped one: three controls, six rows.
    assert (frameworks["finos-aigf"]["totalControls"],
            frameworks["finos-aigf"]["totalResults"]) == (3, 6)
    assert (frameworks["finos-aigf"]["passedControls"],
            frameworks["finos-aigf"]["failedControls"]) == (3, 0)
    assert summary["totalChecks"] == 10
    assert fake.audit[0]["detail"]["checks_unmapped"] == 2


# --------------------------------------------------------------------------
# A malformed engine result (M2)
# --------------------------------------------------------------------------

def without(result: dict[str, Any], *keys: str) -> dict[str, Any]:
    return {k: v for k, v in result.items() if k not in keys}


@pytest.mark.asyncio
@pytest.mark.parametrize("field,value", [
    ("ale", None),
    ("var95", "1234.5"),
    ("tvar", float("nan")),
    ("carriedGbp", float("inf")),
    ("carriedGbp", True),
])
async def test_an_unreadable_money_figure_errors_that_check_not_the_tenant_scan(db, field, value):
    """M2: ``float(None)`` and ``float('nan')`` used to reach the response model
    and 500 the whole tenant's scan.  One malformed result is one errored
    check, and its figure is never defaulted to a number nobody computed."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)],
                     controls=[CONTROLS[0], CONTROLS[1]]))
    bad = item("cis-kubernetes", "no-privileged-containers", "pass")
    bad[field] = value
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(
            [bad, item("cis-kubernetes", "no-root-containers", "pass")]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["agentsFailed"] == []
    [bad_check, good_check] = data["checks"]
    assert (bad_check["status"], bad_check["passed"]) == ("error", False)
    assert field in bad_check["error"], bad_check["error"]
    # The verdict the engine sent for it does not survive the defect.
    assert fake.results[(AGENT_A, CTRL_PRIV)]["status"] == "error"
    assert good_check["status"] == "pass"
    assert (data["summary"]["passed"], data["summary"]["errored"]) == (1, 1)


@pytest.mark.asyncio
@pytest.mark.parametrize("missing", [("status", "passed"), ("status", "passed", "ale")])
async def test_a_result_with_neither_status_nor_passed_errors_with_a_reason(db, missing):
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(
            [without(item("cis-kubernetes", "no-privileged-containers", "pass"), *missing)]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    [check] = resp.json()["checks"]
    assert check["status"] == "error"
    assert check["error"] == "engine result carried neither status nor passed"
    assert fake.results[(AGENT_A, CTRL_PRIV)]["status"] == "error"


@pytest.mark.asyncio
async def test_a_missing_calibration_source_or_timestamp_is_null_not_invented(db):
    """M2: the engine's provenance is reported or it is absent.  Defaulting
    ``calibrationSource`` to ``industry-indicative`` asserted a calibration for
    a figure whose calibration was never reported; defaulting ``scanTimestamp``
    to now asserted the engine had just looked."""
    db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([without(
            item("cis-kubernetes", "no-privileged-containers", "fail"),
            "calibrationSource", "scanTimestamp")]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    [check] = resp.json()["checks"]
    assert (check["status"], check["calibrationSource"], check["scanTimestamp"]) == ("fail", None, None)
    # The summary still needs a time; it is the response's own, not a claim
    # about an engine answer that carried none.
    assert resp.json()["summary"]["scanTimestamp"]


# --------------------------------------------------------------------------
# Concurrent scans of one tenant (H3)
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_the_write_transaction_locks_the_tenant_before_it_touches_a_row(db):
    """H3: a scan reads the registry, makes slow sequential engine calls, then
    upserts.  Two scans of one tenant therefore interleave their writes unless
    the write half is serialised per tenant.  The lock is taken inside the
    transaction (``pg_advisory_xact_lock``), so it is released by commit or
    rollback and never leaks on an exception."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(
            [item("cis-kubernetes", "no-privileged-containers", "pass")]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert fake.statements == [
        ("lock", EAP_TENANT_A),
        ("result", AGENT_A, CTRL_PRIV),
        ("audit", "compliance.scan_completed"),
    ]


@pytest.mark.asyncio
async def test_the_upsert_records_the_scan_start_so_freshness_orders_by_scan(db):
    """H3: the stored ``assessed_at`` is the instant this scan's view of the
    registry was taken, not the instant it got round to writing.  A slow scan
    that finishes last must not look like the most recent assessment."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    before = datetime.now(timezone.utc)
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering(
            [item("cis-kubernetes", "no-privileged-containers", "pass")]))
        resp = await scan(SCAN)
    after = datetime.now(timezone.utc)
    assert resp.status_code == 200, resp.text
    stored_at = fake.assessed[(AGENT_A, CTRL_PRIV)]
    assert before <= stored_at <= after
    # The scan response's timestamp comes from the engine; assessed_at is ours.
    assert stored_at.tzinfo is not None


# --------------------------------------------------------------------------
# No cross-agent stamping
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_each_verdict_lands_on_its_own_agent_only(db):
    fake = db(FakeDB(
        agents=[
            agent_row(AGENT_A, "agent-a", workload=POD_A),
            agent_row(AGENT_B, "agent-b", workload=DEPLOYMENT),
            agent_row(AGENT_C, "agent-c"),
        ],
        controls=[CONTROLS[0]],
    ))
    # C was assessed earlier and is not part of this scan.
    fake.results[(AGENT_C, CTRL_PRIV)] = {"tenant_id": EAP_TENANT_A, "status": "pending", "evidence_ref": None}

    def by_agent(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        verdict = "fail" if body["object"]["metadata"].get("name") == "agent-a" else "pass"
        return answering([item("cis-kubernetes", "no-privileged-containers", verdict)])(request)

    with respx.mock() as mock:
        route = mock.post(ENGINE).mock(side_effect=by_agent)
        resp = await scan({**SCAN, "agentIds": [str(AGENT_A), str(AGENT_B)]})

    assert resp.status_code == 200, resp.text
    assert route.call_count == 2  # two agents x one mapped pack; C is never asked about
    assert {key: row["status"] for key, row in fake.results.items()} == {
        (AGENT_A, CTRL_PRIV): "fail",
        (AGENT_B, CTRL_PRIV): "pass",
        (AGENT_C, CTRL_PRIV): "pending",
    }


@pytest.mark.asyncio
async def test_versions_that_disagree_resolve_to_the_worse_verdict(db):
    """The engine scans every version of a pack; one control, one stored row."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0], CONTROLS[1]]))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([
            item("cis-kubernetes", "no-privileged-containers", "pass"),
            item("cis-kubernetes", "no-privileged-containers", "fail"),
            item("cis-kubernetes", "no-root-containers", "pass"),
            item("cis-kubernetes", "no-root-containers", "error"),
        ]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert {key: row["status"] for key, row in fake.results.items()} == {
        (AGENT_A, CTRL_PRIV): "fail",
        (AGENT_A, CTRL_ROOT): "error",
    }


@pytest.mark.asyncio
@pytest.mark.parametrize("order", ["worst-first", "worst-last"])
async def test_the_stored_evidence_names_the_result_the_worst_verdict_came_from(db, order):
    """L4: a control assessed by several results in one scan stores the worst
    verdict, and the evidence must point at the result that verdict came from.
    It used to be overwritten by whichever result arrived last, so the row read
    ``fail`` while citing the evaluation that passed -- the one thing a piece of
    regulatory evidence must never do."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    passing = item("cis-kubernetes", "no-privileged-containers", "pass")
    passing["policyVersion"] = "v1.8.0-rc1"
    failing = item("cis-kubernetes", "no-privileged-containers", "fail")
    results = [failing, passing] if order == "worst-first" else [passing, failing]

    with respx.mock() as mock:
        mock.post(ENGINE).mock(return_value=httpx.Response(200, json=results))
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    assert fake.results[(AGENT_A, CTRL_PRIV)] == {
        "tenant_id": EAP_TENANT_A, "status": "fail",
        "evidence_ref": "policy-engine:cis-kubernetes/no-privileged-containers@v1.8.0",
    }


@pytest.mark.asyncio
async def test_results_of_equal_verdict_keep_the_first_result_as_evidence(db):
    """``worse`` keeps the earlier verdict on a tie, so the evidence does too:
    one deterministic choice rather than one per field."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=[CONTROLS[0]]))
    first = item("cis-kubernetes", "no-privileged-containers", "pass")
    second = item("cis-kubernetes", "no-privileged-containers", "pass")
    second["policyVersion"] = "v1.8.0-rc1"
    with respx.mock() as mock:
        mock.post(ENGINE).mock(return_value=httpx.Response(200, json=[first, second]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert fake.results[(AGENT_A, CTRL_PRIV)]["evidence_ref"] == \
        "policy-engine:cis-kubernetes/no-privileged-containers@v1.8.0"


@pytest.mark.asyncio
async def test_each_pack_is_asked_at_the_version_it_is_activated_at(db):
    """L3: each pack is asked at its own ``governance_frameworks.version``; the
    request's ``policyVersion`` is only the fallback for a pack this tenant has
    not mapped.  Asked here with a version no pack carries, every mapped check
    still comes back -- which only holds if the per-pack lookup is doing the
    work, because the engine answers nothing for a version it has no checks
    for."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=CONTROLS))
    with respx.mock() as mock:
        route = mock.post(ENGINE).mock(side_effect=answering(EVERY_CHECK_PASSES))
        resp = await scan({**SCAN, "policyVersion": "v99.0.0"})

    assert resp.status_code == 200, resp.text
    assert sorted(json.loads(c.request.content)["policyVersion"] for c in route.calls) == [
        "v1.0.0", "v1.8.0"]
    data = resp.json()
    assert (data["agentsFailed"], data["agentsScanned"]) == ([], 1)
    assert len(data["checks"]) == len(CONTROLS)
    # The stored evidence names the version the check was evaluated at, not the
    # one the caller typed.
    assert all("@v99" not in row["evidence_ref"] for row in fake.results.values())
    assert {c["policyVersion"] for c in data["checks"]} == {"v1.0.0", "v1.8.0"}
    # The audit records what the packs were evaluated at, not only what the
    # caller asked for: re-pinning to the activated version is deliberate, but
    # it must not be silent.
    detail = fake.audit[0]["detail"]
    assert detail["policy_version"] == "v99.0.0"
    assert detail["pack_versions"] == {"v1.8.0": ["cis-kubernetes"], "v1.0.0": ["finos-aigf"]}
    # And the response says it per framework.
    assert {f["id"]: f["versions"] for f in data["summary"]["frameworks"]} == {
        "cis-kubernetes": ["v1.8.0"], "finos-aigf": ["v1.0.0"]}


# --------------------------------------------------------------------------
# Engine unavailable: nothing changes, nothing is invented
# --------------------------------------------------------------------------

@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["connect", "status500", "not-a-list"])
async def test_engine_unavailable_changes_no_rows_and_invents_no_checks(db, failure):
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a"), agent_row(AGENT_B, "agent-b")], controls=CONTROLS))
    fake.results[(AGENT_A, CTRL_PRIV)] = {"tenant_id": EAP_TENANT_A, "status": "pending", "evidence_ref": None}
    before = dict(fake.results)

    with respx.mock() as mock:
        route = mock.post(ENGINE)
        if failure == "connect":
            route.mock(side_effect=httpx.ConnectError("refused"))
        elif failure == "status500":
            route.mock(return_value=httpx.Response(500, json={"error": "boom"}))
        else:
            route.mock(return_value=httpx.Response(200, json={"error": "not a list"}))
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["engineInvoked"] is False
    assert data["checks"] == []
    assert data["agentsScanned"] == 0
    assert data["agentsFailed"] == [str(AGENT_A), str(AGENT_B)]
    assert (data["summary"]["totalChecks"], data["summary"]["passed"],
            data["summary"]["failed"], data["summary"]["errored"]) == (0, 0, 0, 0)
    assert fake.results == before
    assert fake.result_writes == 0
    detail = fake.audit[0]["detail"]
    assert (detail["engine_invoked"], detail["controls_assessed"], detail["agents_failed"]) == (False, 0, 2)


@pytest.mark.asyncio
async def test_an_agent_with_one_failed_pack_call_keeps_all_its_rows(db):
    """No partial reconcile: half an assessment would read as a complete one."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A),
                             agent_row(AGENT_B, "agent-b", workload=DEPLOYMENT)], controls=[CONTROLS[0], CONTROLS[3]]))

    def flaky(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        if body["frameworks"] == ["finos-aigf"] and body["agent"] == {}:
            if not getattr(flaky, "failed", False):
                flaky.failed = True  # A's AIGF call fails, B's succeeds
                return httpx.Response(503)
        return answering([item("cis-kubernetes", "no-privileged-containers", "pass"),
                          item("finos-aigf", "prompt-injection-guardrail-active", "fail")])(request)

    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=flaky)
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert (data["engineInvoked"], data["agentsScanned"], data["agentsFailed"]) == (True, 1, [str(AGENT_A)])
    assert {key: row["status"] for key, row in fake.results.items()} == {
        (AGENT_B, CTRL_PRIV): "pass",
        (AGENT_B, CTRL_PI): "fail",
    }
    assert {c["agentId"] for c in data["checks"]} == {str(AGENT_B)}


@pytest.mark.asyncio
async def test_no_mapped_frameworks_means_no_engine_call(db):
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a")], controls=[]))
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(ENGINE).mock(return_value=httpx.Response(200, json=[]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert not route.called
    assert resp.json()["engineInvoked"] is False
    assert fake.result_writes == 0


@pytest.mark.asyncio
async def test_an_agent_without_a_workload_gets_object_only_controls_pending_not_assessed(db):
    """H1: no observed workload, no CIS assessment -- neither 17x fail (the engine's
    answer for {}) nor a stale verdict from an earlier workload."""
    fake = db(FakeDB(agents=[agent_row(AGENT_B, "agent-b")], controls=CONTROLS))
    fake.results[(AGENT_B, CTRL_PRIV)] = {"tenant_id": EAP_TENANT_A, "status": "pass", "evidence_ref": "old"}
    with respx.mock() as mock:
        route = mock.post(ENGINE).mock(side_effect=answering([
            item("cis-kubernetes", "no-privileged-containers", "fail"),
            item("cis-kubernetes", "no-root-containers", "fail"),
            item("finos-aigf", "registered-model-registry-entry", "pass"),
            item("finos-aigf", "prompt-injection-guardrail-active", "fail"),
        ]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert [json.loads(c.request.content)["frameworks"] for c in route.calls] == [["finos-aigf"]]
    assert {k: (r["status"], r["evidence_ref"]) for k, r in fake.results.items()} == {
        (AGENT_B, CTRL_PRIV): ("pending", None),
        (AGENT_B, CTRL_ROOT): ("pending", None),
        (AGENT_B, CTRL_MODEL): ("pass", "policy-engine:finos-aigf/registered-model-registry-entry@v1.0.0"),
        (AGENT_B, CTRL_PI): ("fail", "policy-engine:finos-aigf/prompt-injection-guardrail-active@v1.0.0"),
    }
    assert fake.assessed[(AGENT_B, CTRL_PRIV)] is None and fake.assessed[(AGENT_B, CTRL_ROOT)] is None
    data = resp.json()
    assert {c["framework"] for c in data["checks"]} == {"finos-aigf"}
    assert sorted((g["agentId"], g["framework"], g["check"], g["controlId"], g["stored"], g["reason"])
                  for g in data["controlGaps"]) == [
        (str(AGENT_B), "cis-kubernetes", "no-privileged-containers", str(CTRL_PRIV), "pending", "no_workload"),
        (str(AGENT_B), "cis-kubernetes", "no-root-containers", str(CTRL_ROOT), "pending", "no_workload"),
    ]
    assert (data["agentsScanned"], data["engineInvoked"]) == (1, True)
    assert fake.audit[0]["detail"]["controls_no_workload"] == 2


@pytest.mark.asyncio
async def test_a_cis_only_scan_of_an_agent_without_a_workload_calls_no_engine(db):
    fake = db(FakeDB(agents=[agent_row(AGENT_B, "agent-b")], controls=CONTROLS))
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(ENGINE).mock(return_value=httpx.Response(200, json=[]))
        resp = await scan({**SCAN, "frameworks": ["cis-kubernetes"]})
    assert resp.status_code == 200, resp.text
    assert not route.called
    assert resp.json()["engineInvoked"] is False
    assert {k: r["status"] for k, r in fake.results.items()} == {
        (AGENT_B, CTRL_PRIV): "pending", (AGENT_B, CTRL_ROOT): "pending"}


@pytest.mark.asyncio
async def test_a_mapped_check_missing_from_the_engine_answer_is_stored_as_error(db):
    """H2: a partial 200 must not leave the missing control's earlier verdict standing."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=CONTROLS))
    fake.results[(AGENT_A, CTRL_ROOT)] = {"tenant_id": EAP_TENANT_A, "status": "pass", "evidence_ref": "old"}
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([
            item("cis-kubernetes", "no-privileged-containers", "pass"),
            # no-root-containers: absent from the answer
            item("finos-aigf", "registered-model-registry-entry", "pass"),
            item("finos-aigf", "prompt-injection-guardrail-active", "pass"),
        ]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert (fake.results[(AGENT_A, CTRL_ROOT)]["status"], fake.results[(AGENT_A, CTRL_ROOT)]["evidence_ref"]) \
        == ("error", None)
    assert fake.assessed[(AGENT_A, CTRL_ROOT)] is not None
    data = resp.json()
    assert [(g["check"], g["stored"], g["reason"]) for g in data["controlGaps"]] == [
        ("no-root-containers", "error", "missing_from_engine_response")]
    assert data["agentsFailed"] == []
    assert fake.audit[0]["detail"]["controls_missing_from_engine"] == 1


@pytest.mark.asyncio
async def test_an_empty_answer_for_mapped_checks_is_an_engine_failure_for_that_agent(db):
    """H2: ``[]`` where checks were expected is not "nothing to report"."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=CONTROLS))
    fake.results[(AGENT_A, CTRL_PRIV)] = {"tenant_id": EAP_TENANT_A, "status": "pass", "evidence_ref": "old"}
    before = dict(fake.results)

    def empty_aigf(request: httpx.Request) -> httpx.Response:
        if json.loads(request.content)["frameworks"] == ["finos-aigf"]:
            return httpx.Response(200, json=[])
        return answering([item("cis-kubernetes", "no-privileged-containers", "fail"),
                          item("cis-kubernetes", "no-root-containers", "fail")])(request)

    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=empty_aigf)
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert (data["agentsFailed"], data["agentsScanned"], data["checks"]) == ([str(AGENT_A)], 0, [])
    assert fake.results == before
    assert fake.result_writes == 0


# --------------------------------------------------------------------------
# Agent scoping, honest failure reporting, strict mode, and unmapped frameworks
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_scan_scoped_to_agent_ids_scans_only_requested_agents(db):
    """Ensure request.agentIds correctly isolates evaluation to requested agents."""
    fake = db(FakeDB(
        agents=[
            agent_row(AGENT_A, "agent-a", workload=POD_A),
            agent_row(AGENT_B, "agent-b", workload=DEPLOYMENT),
        ],
        controls=[CONTROLS[0]],  # cis-kubernetes: no-privileged-containers
    ))
    fake.results[(AGENT_B, CTRL_PRIV)] = {"tenant_id": EAP_TENANT_A, "status": "pending", "evidence_ref": "untouched"}
    before_b = dict(fake.results[(AGENT_B, CTRL_PRIV)])

    with respx.mock() as mock:
        mock.post(ENGINE).mock(return_value=httpx.Response(200, json=[
            item("cis-kubernetes", "no-privileged-containers", "pass"),
        ]))
        resp = await scan({**SCAN, "agentIds": [str(AGENT_A)]})

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["agentsScanned"] == 1
    assert data["agentsFailed"] == []
    assert {c["agentId"] for c in data["checks"]} == {str(AGENT_A)}
    # B was neither scanned by the engine nor touched in the DB
    assert fake.results[(AGENT_B, CTRL_PRIV)] == before_b
    assert fake.results[(AGENT_A, CTRL_PRIV)]["status"] == "pass"


@pytest.mark.asyncio
async def test_engine_failure_honestly_reports_status_error_and_gaps(db):
    """When policy-engine fails, response honestly communicates failure, error, and gaps."""
    fake = db(FakeDB(
        agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)],
        controls=[CONTROLS[0], CONTROLS[1]],
    ))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(return_value=httpx.Response(500, json={"error": "internal error"}))
        resp = await scan(SCAN)

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["engineInvoked"] is False
    assert data["status"] == "failed"
    assert "policy-engine scan" in data["error"] or "HTTP 500" in data["error"]
    assert data["agentsFailed"] == [str(AGENT_A)]
    assert data["agentsScanned"] == 0
    # Must report actionable gaps for the failed agent
    assert any(g["reason"] == "engine_error" and g["agentId"] == str(AGENT_A) for g in data["controlGaps"])
    # Summary must not lie that risk was priced at 0
    assert data["summary"]["pricing"]["status"] == "NO_RISK_DATA_PLANE"
    assert data["summary"]["totalCarriedGbp"] is None


@pytest.mark.asyncio
async def test_engine_failure_strict_mode_raises_502(db):
    """When strict/failOnError is requested, an engine failure raises HTTP 502."""
    fake = db(FakeDB(
        agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)],
        controls=[CONTROLS[0]],
    ))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=httpx.ConnectError("connection refused"))
        resp = await scan({**SCAN, "strict": True})

    assert resp.status_code == 502, resp.text
    error = resp.json()["error"]
    assert error["code"] == "policy_engine_unavailable"


@pytest.mark.asyncio
async def test_unmapped_framework_does_not_silently_pass_with_zero_results(db):
    """Scanning an unmapped framework does not silently claim clean green zero-result scan."""
    fake = db(FakeDB(
        agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)],
        controls=[CONTROLS[0]],  # cis-kubernetes mapped, but soc-2 is unmapped
    ))
    with respx.mock():
        resp = await scan({**SCAN, "frameworks": ["soc-2"]})

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["engineInvoked"] is False
    assert data["status"] == "failed"
    assert "unmapped" in data["error"].lower()
    assert any(g["reason"] == "unmapped_framework" for g in data["controlGaps"])

