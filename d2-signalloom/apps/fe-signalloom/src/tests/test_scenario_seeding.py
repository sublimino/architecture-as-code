# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_scenario_seeding.py
# Unit and contract tests for Signal Loom EAP Scenario Seeding Engine (SLES)
# ==============================================================================
from datetime import datetime, timezone
import pytest
from fastapi.testclient import TestClient

from scenario_seeding import (
    ScenarioType,
    SyntheticAuditEvent,
    ScenarioManager,
    GLOBAL_SCENARIO_MANAGER,
    generate_baseline_agent_events,
    generate_prompt_injection_intercept_events,
    generate_lateral_traversal_blocked_events,
    generate_compliance_proof_events,
)
from main import app

client = TestClient(app)


def test_baseline_agent_events_generation():
    """Verify baseline agent workflow generates expected control/data/policy events."""
    events = generate_baseline_agent_events("kurasi", "6f82ad81")
    assert len(events) == 3

    # Check planes
    planes = [e.plane for e in events]
    assert "control" in planes
    assert "data" in planes
    assert "policy" in planes

    # Check tenant isolation attributes
    for event in events:
        assert event.customer_hash == "6f82ad81"
        assert event.company_name == "kurasi"
        assert event.namespace == "eap-6f82ad81"
        assert event.verdict == "ALLOW"
        assert event.risk_score <= 0.15


def test_prompt_injection_intercept_events():
    """Verify prompt injection scenario generates detection, intercept, and quarantine events."""
    events = generate_prompt_injection_intercept_events("kurasi", "6f82ad81")
    assert len(events) == 3

    verdicts = [e.verdict for e in events]
    assert "ALLOW" in verdicts
    assert "INTERCEPT" in verdicts
    assert "BLOCK" in verdicts

    # Intercept event must reflect high risk score and guardrail detail
    intercept_event = next(e for e in events if e.verdict == "INTERCEPT")
    assert intercept_event.risk_score >= 0.90
    assert intercept_event.details["guardrail_rule_id"] == "SEC-PROMPT-0412"
    assert "override" in intercept_event.details["violation"].lower()


def test_lateral_traversal_blocked_events():
    """Verify lateral movement attempt generates network policy block event."""
    events = generate_lateral_traversal_blocked_events("kurasi", "6f82ad81")
    assert len(events) == 2

    block_event = next(e for e in events if e.verdict == "BLOCK")
    assert block_event.plane == "policy"
    assert block_event.agent_id == "kubesec-afm-firewall"
    assert block_event.risk_score >= 0.90
    assert block_event.details["target_namespace"] == "production-core"
    assert block_event.details["remediation"] == "Packet dropped at CNI ingress boundary"


def test_compliance_proof_events():
    """Verify compliance attestation proof generates transit-signed event."""
    events = generate_compliance_proof_events("kurasi", "6f82ad81")
    assert len(events) == 1

    proof = events[0]
    assert proof.plane == "control"
    assert proof.verdict == "ALLOW"
    assert proof.risk_score == 0.0
    assert proof.details["key_mount"] == "transit/keys/eap-6f82ad81"
    assert "spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app" in proof.details["spiffe_id"]


def test_scenario_manager_execution_and_storage():
    """Verify ScenarioManager tracks execution history and customer event indexing."""
    mgr = ScenarioManager()

    res = mgr.execute_scenario(ScenarioType.BASELINE_AGENT_FLOW, "kurasi", "6f82ad81")
    assert res.customer_hash == "6f82ad81"
    assert res.events_generated_count == 3
    assert res.duration_ms >= 0.0

    # Retrieve indexed events
    events = mgr.get_events_for_customer("6f82ad81")
    assert len(events) == 3

    # Add another scenario
    res2 = mgr.execute_scenario(ScenarioType.PROMPT_INJECTION_INTERCEPT, "kurasi", "6f82ad81")
    assert res2.events_generated_count == 3

    events_all = mgr.get_events_for_customer("6f82ad81")
    assert len(events_all) == 6

    history = mgr.get_history()
    assert len(history) == 2


def test_api_execute_scenario_endpoint():
    """Verify POST /api/v1/eap/scenarios/execute returns 201 Created and structured result."""
    payload = {
        "scenario_type": "lateral_traversal_blocked",
        "company_name": "kurasi",
        "customer_hash": "6f82ad81",
    }
    resp = client.post("/api/v1/eap/scenarios/execute", json=payload)
    assert resp.status_code == 201
    data = resp.json()

    assert data["customer_hash"] == "6f82ad81"
    assert data["scenario_type"] == "lateral_traversal_blocked"
    assert data["events_generated_count"] == 2
    assert len(data["events"]) == 2


def test_api_get_customer_events_endpoint():
    """Verify GET /api/v1/eap/scenarios/events/{customer_hash} returns generated events."""
    # Execute a scenario first
    client.post("/api/v1/eap/scenarios/execute", json={
        "scenario_type": "compliance_proof",
        "company_name": "kurasi",
        "customer_hash": "6f82ad81",
    })

    resp = client.get("/api/v1/eap/scenarios/events/6f82ad81")
    assert resp.status_code == 200
    events = resp.json()
    assert isinstance(events, list)
    assert len(events) >= 1

    # Check for compliance proof event
    assert any(e["agent_id"] == "signalloom-attestor" for e in events)


def test_api_get_history_endpoint():
    """Verify GET /api/v1/eap/scenarios/history returns execution log."""
    resp = client.get("/api/v1/eap/scenarios/history")
    assert resp.status_code == 200
    history = resp.json()
    assert isinstance(history, list)
    assert len(history) >= 1
