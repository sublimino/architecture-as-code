# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_eap_audit_events.py
# Contract & Integrity Suite for EAP Audit Decisions, MultiPlane Events,
# Transit Signatures, Deterministic Seeding, and Lifecycle Expunge.
# ==============================================================================
from __future__ import annotations

import ast
from datetime import datetime, timezone
import random
import pytest

from environment_lifecycle import (
    GLOBAL_LIFECYCLE_MANAGER,
    EnvironmentLifecycleState,
    LifecycleManager,
)
from scenario_seeding import (
    GLOBAL_SCENARIO_MANAGER,
    ScenarioManager,
    ScenarioType,
    SyntheticAuditEvent,
    generate_baseline_agent_events,
    generate_compliance_proof_events,
    generate_lateral_traversal_blocked_events,
    generate_prompt_injection_intercept_events,
)
from tenant_isolation import (
    GLOBAL_TENANT_ISOLATION_MANAGER,
    TenantIsolationManager,
    get_tenant_namespace,
    get_tenant_spiffe_id,
    get_tenant_transit_key_name,
)
from tenant_transit import InMemoryTransitBackend
from tests.test_audit_provenance import (
    AUDIT_DECISION_OWED,
    NOT_AUDIT_WORTHY,
    _function_table,
    _mutating_routes,
    _reaches_an_audit_writer,
)


def test_every_eap_mutating_route_reaches_audit() -> None:
    """Every mutating route across EAP modules reaches an audit writer (or is declared in NOT_AUDIT_WORTHY / AUDIT_DECISION_OWED)."""
    table = _function_table()
    declared = {**NOT_AUDIT_WORTHY, **AUDIT_DECISION_OWED}
    eap_modules = {
        "tenant_isolation.py",
        "scenario_seeding.py",
        "environment_routing.py",
        "environment_lifecycle.py",
    }
    eap_mutating = [
        (mod, handler, verb, route, audited)
        for mod, handler, verb, route, audited in _mutating_routes()
        if mod in eap_modules
    ]
    assert len(eap_mutating) >= 8, f"Expected at least 8 EAP mutating routes, found {len(eap_mutating)}"
    unaudited = [
        f"{mod}:{handler}"
        for mod, handler, _, _, audited in eap_mutating
        if not audited and (mod, handler) not in declared
    ]
    assert not unaudited, f"Found unaudited EAP mutating routes: {unaudited}"


def test_positive_control_non_auditing_route_is_detected() -> None:
    """Positive control: a function that does not audit is correctly identified as False."""
    table = _function_table()
    # release_agent_claim in api_compat.py does not write audit records
    assert not _reaches_an_audit_writer("release_agent_claim", table)


def test_all_seeded_events_carry_spiffe_and_multiplane_fields() -> None:
    """All 9 synthetic events across all 4 scenarios carry required MultiPlane fields and tenant SPIFFE."""
    customer_hash = "a1b2c3d4"
    company = "acme-corp"
    spiffe = get_tenant_spiffe_id(customer_hash)
    ns = get_tenant_namespace(customer_hash)

    events: list[SyntheticAuditEvent] = []
    events.extend(generate_baseline_agent_events(company, customer_hash))
    events.extend(generate_prompt_injection_intercept_events(company, customer_hash))
    events.extend(generate_lateral_traversal_blocked_events(company, customer_hash))
    events.extend(generate_compliance_proof_events(company, customer_hash))

    assert len(events) == 9, f"Expected 9 total synthetic events, got {len(events)}"

    required_fields = {
        "event_id",
        "event_type",
        "timestamp",
        "plane",
        "source_agent",
        "target_resource",
        "spiffe_id",
        "action",
        "verdict",
        "risk_score",
    }

    for ev in events:
        dump = ev.model_dump()
        for field in required_fields:
            assert dump.get(field) is not None, f"Event {ev.event_id} missing field {field}"
        assert ev.spiffe_id == spiffe
        assert ev.namespace == ns
        assert ev.customer_hash == customer_hash
        assert ev.event_type and "." in ev.event_type


def test_compliance_proof_transit_signature_and_verification() -> None:
    """Compliance proof carries a verifiable OpenBao transit signature; controls fail on tampering."""
    backend = InMemoryTransitBackend()
    customer_hash = "77aa88bb"
    company = "crypto-tenant"
    key_name = get_tenant_transit_key_name(customer_hash)
    spiffe = get_tenant_spiffe_id(customer_hash)

    events = generate_compliance_proof_events(company, customer_hash, transit_backend=backend)
    assert len(events) == 1
    proof = events[0]

    sig = proof.details.get("signature")
    assert isinstance(sig, str) and sig.startswith("vault:v1:")

    raw_payload = f"compliance-attestation:{customer_hash}:{spiffe}:{company}".encode("utf-8")
    valid = backend.verify(key_name, raw_payload, sig)
    assert valid is True, "Transit signature must verify successfully against original payload"

    # Negative control 1: Payload corrupted by 1 byte
    tampered_payload = bytearray(raw_payload)
    tampered_payload[0] ^= 0xFF
    assert backend.verify(key_name, bytes(tampered_payload), sig) is False

    # Negative control 2: Verification against another tenant's key
    other_key = get_tenant_transit_key_name("99cc00dd")
    backend.create_key(other_key)
    assert backend.verify(other_key, raw_payload, sig) is False


def test_deterministic_generation_seeded_rng_and_clock() -> None:
    """Byte-identical model_dump_json outputs under fixed seed and clock; divergence on modification."""
    customer_hash = "beef1234"
    company = "det-test"
    fixed_clock = lambda: datetime(2026, 9, 23, 14, 30, 45, 123456, tzinfo=timezone.utc)

    mgr1 = ScenarioManager(rng_seed=424242, clock=fixed_clock)
    mgr2 = ScenarioManager(rng_seed=424242, clock=fixed_clock)

    res1 = [mgr1.execute_scenario(st, company, customer_hash) for st in ScenarioType]
    res2 = [mgr2.execute_scenario(st, company, customer_hash) for st in ScenarioType]

    events_json1 = [e.model_dump_json() for r in res1 for e in r.events]
    events_json2 = [e.model_dump_json() for r in res2 for e in r.events]
    exec_ids1 = [r.execution_id for r in res1]
    exec_ids2 = [r.execution_id for r in res2]

    assert events_json1 == events_json2, "Deterministic runs must produce byte-identical event JSON outputs"
    assert exec_ids1 == exec_ids2, "Execution IDs must be identical under identical seed"

    # Negative control: Divergent seed
    mgr3 = ScenarioManager(rng_seed=999999, clock=fixed_clock)
    res3 = [mgr3.execute_scenario(st, company, customer_hash) for st in ScenarioType]
    events_json3 = [e.model_dump_json() for r in res3 for e in r.events]
    assert events_json3 != events_json1

    # Negative control: Divergent clock
    diff_clock = lambda: datetime(2026, 9, 23, 14, 30, 45, 999999, tzinfo=timezone.utc)
    mgr4 = ScenarioManager(rng_seed=424242, clock=diff_clock)
    res4 = [mgr4.execute_scenario(st, company, customer_hash) for st in ScenarioType]
    events_json4 = [e.model_dump_json() for r in res4 for e in r.events]
    assert events_json4 != events_json1


def test_auto_seed_on_register_and_expunge_on_reap() -> None:
    """Auto-seeds baseline events upon registration and expunges only reaped tenant's data."""
    c1 = "tenant-one"
    h1 = "1111aaaa"
    c2 = "tenant-two"
    h2 = "2222bbbb"

    # Register tenant 1 and tenant 2
    r1 = GLOBAL_LIFECYCLE_MANAGER.register_environment(c1, h1, ttl_minutes=60)
    r2 = GLOBAL_LIFECYCLE_MANAGER.register_environment(c2, h2, ttl_minutes=60)

    # Verify auto-seeded events exist immediately
    ev1 = GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h1)
    ev2 = GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h2)
    assert len(ev1) >= 3, "Tenant 1 should have auto-seeded baseline events"
    assert len(ev2) >= 3, "Tenant 2 should have auto-seeded baseline events"

    # Transition tenant 1 to DRAINING -> events still exist
    GLOBAL_LIFECYCLE_MANAGER.transition_state(h1, EnvironmentLifecycleState.DRAINING)
    assert len(GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h1)) >= 3

    # Transition tenant 1 to TERMINATED -> tenant 1 expunged, tenant 2 intact
    GLOBAL_LIFECYCLE_MANAGER.transition_state(h1, EnvironmentLifecycleState.TERMINATED)
    assert len(GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h1)) == 0
    assert len(GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h2)) >= 3

    # Clean up tenant 2
    GLOBAL_LIFECYCLE_MANAGER.transition_state(h2, EnvironmentLifecycleState.DRAINING)
    GLOBAL_LIFECYCLE_MANAGER.transition_state(h2, EnvironmentLifecycleState.TERMINATED)
    assert len(GLOBAL_SCENARIO_MANAGER.get_events_for_customer(h2)) == 0
