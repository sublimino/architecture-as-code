"""A compliance posture figure is real iff it is a function of its inputs.

Two defects, fixed and pinned together:

F2 -- four live write paths persisted ``compliance_posture = 83`` as though it
had been measured (``/api/v1/agents/claim``, the discovery-portal claim,
external-agent registration, host enrollment), and every
``ON CONFLICT ... DO UPDATE`` reset the column to 83 on re-claim, destroying
any real score computed in between. Because the write path is the liar, a
downstream route that honestly reads the database still served a fabricated
score and looked clean under inspection.

F3 -- ``GET /api/agents`` built posture out of absence:
``float(row.get("compliance_posture", 100)) / 100.0``. ``dict.get`` returns the
default only when the key is ABSENT, and no code path in this tree ever writes
that key into the in-process store, so the default fired for every such row and
published posture 1.0 -- perfect compliance synthesised from no data, strictly
worse than the 83 it replaced. In the same dict ``total_controls`` was the
literal ``6`` and ``passing`` was ``max(6 - fc, 0)``, so the passing count
inherited the fiction without consulting any control catalogue.

They must land together: writing NULL for F2 while leaving F3 in place routes
the reader into ``float(None)`` -> ``TypeError`` -> 500, because the default
does not fire for a key that is present-but-NULL.
"""
from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

SUB = "posture-truth-alice"
TENANT = "tenant-posture-truth"
SUBJECT_TENANTS = {SUB: TENANT}

SRC = Path(api_compat.__file__).parent

#: Every route that persists an ``agent_registry`` row on a lifecycle event.
#: None of them assesses a single control, so none of them may write a posture.
WRITE_PATH_FILES = (
    "api_compat.py",
    "routers/discovery.py",
    "external_agent_registration.py",
    "host_enrollment.py",
)


def _bearer(subject: str = SUB) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
            "email": f"{subject}@signalloom.test",
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key-posture", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _TestJWKClient:
    def get_signing_key_from_jwt(self, _token: str) -> Any:
        from types import SimpleNamespace

        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    async def _no_pool() -> None:
        return None

    # The no-database branch is the one that carried F3.
    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    api_compat.reset_tenant_state(TENANT)
    with api_compat._STORE_LOCK:
        api_compat._AGENTS.setdefault(TENANT, {})


@pytest.fixture
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


def _seed(agent_id: str, **extra: Any) -> None:
    row: dict[str, Any] = {
        "id": agent_id,
        "tenant_id": TENANT,
        "name": agent_id.replace("-", " ").title(),
        "lifecycle_state": "active",
        "status": "active",
        "findings_count": 0,
    }
    row.update(extra)
    with api_compat._STORE_LOCK:
        api_compat._AGENTS[TENANT][agent_id] = row


def _summary_for(client: TestClient, agent_id: str) -> dict[str, Any]:
    res = client.get("/api/agents?page_size=200", headers=_bearer())
    assert res.status_code == 200, res.text
    agents = res.json()["agents"]
    matches = [a for a in agents if a["id"] == agent_id]
    assert matches, f"{agent_id} missing from {[a['id'] for a in agents]}"
    return matches[0]["compliance_summary"]


# ---------------------------------------------------------------------------
# F2 -- the write path
# ---------------------------------------------------------------------------

def test_no_write_path_persists_a_literal_posture() -> None:
    """No INSERT into agent_registry may hard-code a compliance_posture."""
    offenders: list[str] = []
    for rel in WRITE_PATH_FILES:
        src = (SRC / rel).read_text()
        # The old INSERT shape: origin literal, then the posture literal.
        for match in re.finditer(
            r"'(?:Custom|Signal Loom Built)',\s*(\d+)\s*,", src
        ):
            offenders.append(f"{rel}: INSERT persists posture {match.group(1)}")
    assert offenders == [], (
        "a claim/enrollment/registration measures no controls, so it must "
        "write NULL: " + "; ".join(offenders)
    )


def test_reclaim_does_not_reset_posture() -> None:
    """``compliance_posture`` must not appear in any DO UPDATE SET list.

    A re-claim took no measurement. It may neither write a figure nor clear
    one -- resetting the column destroyed any real score computed since the
    first claim, which is the quiet half of this defect.
    """
    offenders: list[str] = []
    for rel in WRITE_PATH_FILES:
        src = (SRC / rel).read_text()
        for block in re.finditer(
            r"ON CONFLICT[^\n]*DO UPDATE SET(.*?)(?:RETURNING|\"\"\")", src, re.S
        ):
            body = block.group(1)
            # Comments explain the omission; only real assignments count.
            statements = "\n".join(
                line for line in body.splitlines() if not line.strip().startswith("--")
            )
            if "compliance_posture" in statements:
                offenders.append(f"{rel}: DO UPDATE SET writes compliance_posture")
    assert offenders == [], "; ".join(offenders)


def test_posture_column_is_nullable_in_the_schema() -> None:
    """The NULL write is schema-legal, which is why refusal is available."""
    migration = (SRC / "db/migrations/004_agent_governance_schema.sql").read_text()
    assert "compliance_posture IS NULL" in migration


# ---------------------------------------------------------------------------
# F3 -- the read path
# ---------------------------------------------------------------------------

def test_absent_posture_is_refused_not_defaulted_to_perfect(client: TestClient) -> None:
    """A row with no posture key must not be published at posture 1.0.

    This is the production shape: nothing in this tree writes a
    ``compliance_posture`` key into the in-process store, so the old
    ``.get("compliance_posture", 100)`` default fired every single time.
    """
    _seed("agent-no-posture", findings_count=0)
    summary = _summary_for(client, "agent-no-posture")
    assert summary["posture_score"] is None
    assert summary["posture_score"] != 1.0
    assert summary["evidence_state"] == "unavailable"
    assert summary["reason"]


def test_present_but_null_posture_does_not_500_and_is_not_redefaulted(
    client: TestClient,
) -> None:
    """The mutant that proves F2 and F3 are one change.

    After F2 the column is NULL, so the key arrives present-but-NULL.
    ``dict.get(k, 100)`` does NOT substitute the default for that, so the old
    reader computed ``float(None)`` and returned 500. The fix must neither
    crash nor quietly resurrect a number.
    """
    _seed("agent-null-posture", compliance_posture=None, findings_count=2)
    summary = _summary_for(client, "agent-null-posture")
    assert summary["posture_score"] is None
    assert summary["evidence_state"] == "unavailable"
    assert summary["failing"] == 2


def test_control_count_is_never_the_literal_six(client: TestClient) -> None:
    """``total_controls`` is the count of assessed controls, or nothing.

    Six was the row count of the demo ``governance_controls`` seed -- a fact
    about one database, not a property of any agent -- and ``passing`` was
    derived from it as ``max(6 - fc, 0)``, so it reported five passing controls
    for an agent assessed against none.
    """
    _seed("agent-three-findings", findings_count=3)
    summary = _summary_for(client, "agent-three-findings")
    assert summary["total_controls"] == 0
    assert summary["total_controls"] != 6
    assert summary["passing"] == 0
    assert summary["passing"] != 3  # max(6 - 3, 0)
    assert summary["failing"] == 3  # derivable from the row, so carried


def test_in_memory_claim_refuses_its_compliance_summary(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The claim response may not restate the seeded path's 6/5/1 + 0.83.

    The database branch seeds one ``agent_compliance_results`` row per
    ``governance_controls`` row and counts the summary off those rows. The
    no-database branch has no catalogue to seed from, so it has no control
    count to report.
    """
    # The claim route fails closed when discovery is unreadable (503
    # discovery_unavailable), so the workload and its registered identity are
    # supplied as fixtures -- same pattern as tests/test_claim_tenancy.py.
    import claim_tenancy
    from agent_identity_map import AgentIdentity

    pod = "posture-truth-pod"
    ns = "fe-signalloom-agents"

    async def _workloads() -> list[dict[str, Any]]:
        return [{
            "id": pod, "name": pod, "agent_name": pod,
            "namespace": ns, "tenant": TENANT, "model": "claude-sonnet-4-5",
            "service_account": pod,
        }]

    monkeypatch.setattr(claim_tenancy, "workload_source", _workloads)
    monkeypatch.setattr(
        claim_tenancy, "identity_map_source",
        lambda: {pod: AgentIdentity(namespace=ns, service_account=pod)},
    )

    res = client.post(
        "/api/v1/agents/claim",
        json={
            "pod_name": "posture-truth-pod",
            "namespace": "fe-signalloom-agents",
            "spiffe_id": "spiffe://cluster.local/ns/fe-signalloom-agents/sa/posture-truth-pod",
            "harness": "claude-code",
            "model": "claude-sonnet-4-5",
            "declared_tools": [],
            "token_budget_limit": 100000,
        },
        headers=_bearer(),
    )
    assert res.status_code == 200, res.text
    summary = res.json().get("compliance_summary")
    if summary is None:  # route may not echo the summary; the store must agree
        summary = _summary_for(client, res.json()["agent_id"])
    assert summary["posture_score"] is None
    assert summary["total_controls"] == 0
    assert summary["evidence_state"] == "unavailable"


@pytest.mark.asyncio
async def test_no_control_results_refuses_rather_than_scoring_zero() -> None:
    """Zero assessed controls is "not assessed", never "posture 0".

    ``cadvisor_poller``'s invariant, applied to compliance: no rate is not a
    zero rate.
    """

    class _Executor:
        async def fetch(self, *_args: Any, **_kwargs: Any) -> list[Any]:
            return []

    summary = await api_compat._compliance_summary_for_agent(
        _Executor(), "00000000-0000-0000-0000-000000000000",
    )
    assert summary.posture_score is None
    assert summary.evidence_state == "unavailable"
    assert summary.reason
    assert summary.total_controls == 0


@pytest.mark.asyncio
async def test_measured_controls_are_reported_as_measured() -> None:
    """The refusal must not swallow a real reading -- a still field has three
    explanations, and "correctly constant" is not a finding."""

    class _Executor:
        async def fetch(self, *_args: Any, **_kwargs: Any) -> list[Any]:
            return [
                {"status": "pass", "cnt": 3},
                {"status": "fail", "cnt": 1},
            ]

    summary = await api_compat._compliance_summary_for_agent(
        _Executor(), "00000000-0000-0000-0000-000000000000",
    )
    assert summary.total_controls == 4
    assert summary.passing == 3
    assert summary.posture_score == 0.75
    assert summary.evidence_state == "measured"
    assert summary.reason is None
