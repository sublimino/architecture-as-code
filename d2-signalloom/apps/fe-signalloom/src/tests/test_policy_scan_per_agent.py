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
from typing import Any

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient

import api_compat
from config import settings
from conftest import EAP_ALICE, EAP_TENANT_A, eap_bearer
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
        if "FROM agent_registry" in query:
            assert args[0] == EAP_TENANT_A
            wanted = set(args[1])
            return [a for a in self.agents if not wanted or str(a["id"]) in wanted]
        if "FROM governance_controls" in query:
            assert args[0] == EAP_TENANT_A
            wanted = set(args[1])
            return [c for c in self.controls if not wanted or c["policy_framework_id"] in wanted]
        raise AssertionError(f"unexpected fetch: {query}")

    async def execute(self, query: str, *args: Any) -> str:
        if "INSERT INTO agent_compliance_results" in query:
            tenant, agent_id, control_id, status, evidence = args
            self.results[(agent_id, control_id)] = {
                "tenant_id": tenant, "status": status, "evidence_ref": evidence,
            }
            self.result_writes += 1
            return "INSERT 0 1"
        if "INSERT INTO audit_events" in query:
            self.audit.append({"event_type": args[1], "detail": json.loads(args[5])})
            return "INSERT 0 1"
        raise AssertionError(f"unexpected execute: {query}")


def agent_row(agent_id, name, *, model_approved=None, context=None, workload=None):
    return {
        "id": agent_id,
        "name": name,
        "model_approved": model_approved,
        # asyncpg returns json/jsonb as text without a codec; the builder must cope.
        "policy_context": json.dumps(context) if context is not None else None,
        "workload_spec": json.dumps(workload) if workload is not None else None,
    }


#: The pack version each tenant framework is activated at (governance_frameworks.version).
PACK_VERSION = {"cis-kubernetes": "v1.8.0", "finos-aigf": "v1.0.0"}


def control(control_id, framework, check):
    return {"control_id": control_id, "policy_framework_id": framework, "policy_check_id": check,
            "framework_version": PACK_VERSION[framework]}


def answering(results):
    """Engine stand-in: answer each call with the results for the packs it asked about."""
    def respond(request: httpx.Request) -> httpx.Response:
        asked = json.loads(request.content)["frameworks"]
        return httpx.Response(200, json=[r for r in results if r["framework"] in asked])
    return respond


CONTROLS = [
    control(CTRL_PRIV, "cis-kubernetes", "no-privileged-containers"),
    control(CTRL_ROOT, "cis-kubernetes", "no-root-containers"),
    control(CTRL_MODEL, "finos-aigf", "registered-model-registry-entry"),
    control(CTRL_PI, "finos-aigf", "prompt-injection-guardrail-active"),
]


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
        route = mock.post(ENGINE).mock(return_value=httpx.Response(200, json=[]))
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
        # No workload on record: no object is sent, so pod checks report
        # what they make of nothing rather than judging a fictional pod.
        {"namespace": "agents", "policyVersion": "v1.8.0", "frameworks": ["cis-kubernetes"],
         "agent": {}, "request": {}},
        {"namespace": "agents", "policyVersion": "v1.0.0", "frameworks": ["finos-aigf"],
         "agent": {}, "request": {}},
    ]
    for call in route.calls:
        assert call.request.headers["X-Tenant-ID"] == EAP_TENANT_A
    assert fake.result_writes == 0


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
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a", workload=POD_A)], controls=CONTROLS))
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
    db(FakeDB(agents=[agent_row(AGENT_A, "agent-a")], controls=CONTROLS))
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
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a")], controls=CONTROLS))
    with respx.mock() as mock:
        mock.post(ENGINE).mock(side_effect=answering([
            item("finos-aigf", "a-check-with-no-seed-row", "pass"),
        ]))
        resp = await scan(SCAN)
    assert resp.status_code == 200, resp.text
    assert fake.results == {}
    [check] = resp.json()["checks"]
    assert (check["status"], check["controlId"]) == ("pass", None)
    assert fake.audit[0]["detail"]["checks_unmapped"] == 1
    assert fake.audit[0]["detail"]["controls_assessed"] == 0


# --------------------------------------------------------------------------
# No cross-agent stamping
# --------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_each_verdict_lands_on_its_own_agent_only(db):
    fake = db(FakeDB(
        agents=[
            agent_row(AGENT_A, "agent-a", workload=POD_A),
            agent_row(AGENT_B, "agent-b"),
            agent_row(AGENT_C, "agent-c"),
        ],
        controls=CONTROLS,
    ))
    # C was assessed earlier and is not part of this scan.
    fake.results[(AGENT_C, CTRL_PRIV)] = {"tenant_id": EAP_TENANT_A, "status": "pending", "evidence_ref": None}

    def by_agent(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        verdict = "fail" if "object" in body else "pass"
        return answering([item("cis-kubernetes", "no-privileged-containers", verdict)])(request)

    with respx.mock() as mock:
        route = mock.post(ENGINE).mock(side_effect=by_agent)
        resp = await scan({**SCAN, "agentIds": [str(AGENT_A), str(AGENT_B)]})

    assert resp.status_code == 200, resp.text
    assert route.call_count == 4  # two agents x two packs; C is never asked about
    assert {key: row["status"] for key, row in fake.results.items()} == {
        (AGENT_A, CTRL_PRIV): "fail",
        (AGENT_B, CTRL_PRIV): "pass",
        (AGENT_C, CTRL_PRIV): "pending",
    }


@pytest.mark.asyncio
async def test_versions_that_disagree_resolve_to_the_worse_verdict(db):
    """The engine scans every version of a pack; one control, one stored row."""
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a")], controls=CONTROLS))
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
    fake = db(FakeDB(agents=[agent_row(AGENT_A, "agent-a"), agent_row(AGENT_B, "agent-b")], controls=CONTROLS))

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
