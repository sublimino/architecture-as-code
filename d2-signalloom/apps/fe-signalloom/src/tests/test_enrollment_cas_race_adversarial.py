"""SLAAT-P1-2: external-agent host-enrollment CAS/replay adversarial suite.

``test_host_enrollment.py`` (AMXO-P3-1) already proves single-use consumption
and a 12-thread concurrent race with exactly one winner via
``concurrent.futures.ThreadPoolExecutor`` + the synchronous ``TestClient``.
This file is deliberately complementary, not a duplicate, and covers three
things that suite does not:

1. True ``asyncio``-level concurrency (cooperative task interleaving via
   ``httpx.AsyncClient`` + ``asyncio.gather``, not OS threads) against the
   SAME atomic compare-and-set redemption path, bounded by a timeout so a
   latent event-loop deadlock fails fast instead of hanging the test run.
   This also empirically verifies an observation made while auditing
   ``enroll_host_handler``'s in-memory fallback branch: it holds a plain
   ``threading.Lock`` (``_HOST_ENROLL_LOCK``) across an ``await`` on
   ``_audit_log_enrollment(None, ...)``. That await never actually suspends
   today (the ``conn is not None`` guard means the in-memory path never
   performs a real ``await``-yielding operation), so this is not exploitable
   as written -- but it is a fragile invariant, not an enforced one. See the
   SLAAT-P1-2 dossier for the LOW-severity robustness finding.
2. Token-hash bit-flip tampering: a single corrupted character must be
   rejected as `invalid_token`, and must NOT burn the real token.
3. Agent-to-token binding: a token minted for agent A cannot be redeemed
   against a different pre-registered agent B's record.
"""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi import FastAPI

import api_compat
from external_agent_registration import (
    ExternalAgentRegistrationRequest,
    register_external_agent_handler,
    reset_external_agent_state,
)
from host_enrollment import (
    issue_enrollment_token_for_agent,
    reset_host_enrollment_state,
)

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "signal-ingest/collectors/agentnono/fixtures/contracts"


def load_fixture(name: str) -> dict[str, Any]:
    data = json.loads((FIXTURES / name).read_text())
    if "valid" in name and isinstance(data, dict):
        data.pop("credential_reference", None)
    return data


@pytest.fixture(autouse=True)
def clean_state():
    reset_external_agent_state()
    reset_host_enrollment_state()
    with api_compat._STORE_LOCK:
        api_compat._AUDIT_EVENTS.clear()
        api_compat._CLAIMS.clear()
    yield
    reset_external_agent_state()
    reset_host_enrollment_state()


@pytest.fixture
def operator_principal() -> api_compat.Principal:
    return api_compat.Principal(tenant="tenant-a", subject="operator-alice", email="alice@agentmaxxing.example")


@pytest.fixture
def app(operator_principal: api_compat.Principal) -> FastAPI:
    app = FastAPI()
    api_compat.install_compatibility_api(app)
    app.dependency_overrides[api_compat.authenticated_principal] = lambda: operator_principal
    return app


async def _register_and_issue_token(agent_id: str, host_id: str, operator_principal: api_compat.Principal) -> str:
    await register_external_agent_handler(
        ExternalAgentRegistrationRequest(agent_id=agent_id, host_id=host_id), operator_principal
    )
    token_resp = await issue_enrollment_token_for_agent(agent_id, "tenant-a", operator_principal, ttl_seconds=3600)
    return token_resp.enrollment_token


# ---------------------------------------------------------------------------
# 1. True async-concurrency CAS race
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_true_asyncio_concurrent_redemption_exactly_one_winner(app: FastAPI, operator_principal: api_compat.Principal):
    agent_id, host_id = "race-agent-001", "race-host-001"
    token = await _register_and_issue_token(agent_id, host_id, operator_principal)
    payload = load_fixture("valid-enrollment.v1.json")
    payload["agent_id"], payload["host_id"] = agent_id, host_id

    num_tasks = 16
    transport = httpx.ASGITransport(app=app)

    async def _attempt(idx: int, client: httpx.AsyncClient) -> int:
        body = dict(payload)
        body["client_nonce"] = f"nonce-asyncio-{idx:04d}-unique-task"
        resp = await client.post(
            "/v1/external-agents/enroll",
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json=body,
        )
        return resp.status_code

    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        try:
            results = await asyncio.wait_for(
                asyncio.gather(*(_attempt(i, client) for i in range(num_tasks))),
                timeout=15.0,
            )
        except asyncio.TimeoutError:
            pytest.fail(
                "concurrent redemption did not complete within 15s -- possible event-loop "
                "deadlock in enroll_host_handler's in-memory lock path (see module docstring)"
            )

    successes = results.count(201)
    rejections = sum(1 for c in results if c in (401, 409))
    assert successes == 1, f"expected exactly 1 winner under asyncio concurrency, got {successes}: {results}"
    assert rejections == num_tasks - 1, results


# ---------------------------------------------------------------------------
# 2. Token-hash tampering
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_bitflipped_token_is_rejected_and_does_not_burn_the_real_token(
    app: FastAPI, operator_principal: api_compat.Principal
):
    agent_id, host_id = "tamper-agent-001", "tamper-host-001"
    token = await _register_and_issue_token(agent_id, host_id, operator_principal)
    payload = load_fixture("valid-enrollment.v1.json")
    payload["agent_id"], payload["host_id"] = agent_id, host_id

    # Flip the first character (if it's 'a' flip to 'b', else to 'a') -- any
    # single-character corruption must fail the constant-time hash compare.
    tampered = ("b" if token[0] != "b" else "a") + token[1:]
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        bad_resp = await client.post(
            "/v1/external-agents/enroll",
            headers={"Authorization": f"Bearer {tampered}", "Content-Type": "application/json"},
            json=dict(payload, client_nonce="nonce-tampered-attempt"),
        )
        assert bad_resp.status_code == 401, bad_resp.text
        assert bad_resp.json()["error_code"] == "unauthenticated", bad_resp.text

        # The real token must still redeem successfully -- the tampered
        # attempt must not have consumed or corrupted the stored hash.
        good_resp = await client.post(
            "/v1/external-agents/enroll",
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json=dict(payload, client_nonce="nonce-real-attempt-0001"),
        )
        assert good_resp.status_code == 201, good_resp.text


# ---------------------------------------------------------------------------
# 3. Agent-to-token binding (CAS scoping)
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_token_minted_for_one_agent_cannot_redeem_a_different_agent(
    app: FastAPI, operator_principal: api_compat.Principal
):
    token_a = await _register_and_issue_token("bind-agent-a", "bind-host-a", operator_principal)
    await _register_and_issue_token("bind-agent-b", "bind-host-b", operator_principal)

    payload = load_fixture("valid-enrollment.v1.json")
    # Attacker holds token_a (issued for bind-agent-a) and tries to redeem it
    # against bind-agent-b's pre-registration instead.
    cross_payload = dict(payload, agent_id="bind-agent-b", host_id="bind-host-b", client_nonce="nonce-cross-bind-attempt-01")

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.post(
            "/v1/external-agents/enroll",
            headers={"Authorization": f"Bearer {token_a}", "Content-Type": "application/json"},
            json=cross_payload,
        )
    assert resp.status_code in (401, 409), resp.text
    assert resp.status_code != 201, "a token minted for a different agent must never redeem this one"
