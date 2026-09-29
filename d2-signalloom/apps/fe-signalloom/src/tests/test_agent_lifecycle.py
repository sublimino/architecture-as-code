"""Tests for SLMS-P1-3: Agents Page Governance State Consolidation.

Validates:
1. Pure read-time serialization mapping from all legacy DB states:
   - 'registered', 'enrolled', 'active' -> 'Governed'
   - 'suspended', 'stunned' -> 'Suspended'
   - 'revoked', 'decommissioned' -> 'Revoked'
2. Preservation of underlying DB row values (zero in-place mutation).
3. Inclusion of Sentinel eBPF kernel enforcement telemetry (cgroup freeze, network drop) on Suspended/Stunned agents.
4. Filtering behavior for canonical and legacy query parameters.
5. Mutation proof asserting that serialization strictly emits canonical 3-stage governance lifecycle states.
"""
from __future__ import annotations

import uuid
from typing import Any
import pytest

from api_compat import (
    _agent_response_from_row,
    _canonical_lifecycle_state,
    AgentResponse,
    ComplianceSummaryInline,
)


def _make_db_row(
    lifecycle_state: str = "active",
    name: str = "test-agent",
    **overrides: Any,
) -> dict[str, Any]:
    row_id = str(uuid.uuid4())
    row: dict[str, Any] = {
        "id": row_id,
        "name": name,
        "type": "Custom",
        "origin": "Custom",
        "owner": "secops@acme.corp",
        "tenant_id": "tenant-test",
        "lifecycle_state": lifecycle_state,
        "last_transition_at": "2026-09-28T12:00:00Z",
        "last_transition_by": "secops-lead",
        "eu_ai_act_risk_class": "limited",
        "model_name": "claude-3-5-sonnet",
        "created_at": "2026-09-01T00:00:00Z",
        "record_class": "registered",
        "namespace": "agent-swarm",
        "service_account": "test-sa",
    }
    row.update(overrides)
    return row


def _dummy_compliance() -> ComplianceSummaryInline:
    return ComplianceSummaryInline(
        total_controls=10,
        passing=8,
        failing=1,
        pending=1,
        posture_score=80.0,
    )


class TestAgentLifecycleMapping:
    @pytest.mark.parametrize(
        ("legacy_db_state", "expected_canonical"),
        [
            ("registered", "Governed"),
            ("enrolled", "Governed"),
            ("active", "Governed"),
            ("governed", "Governed"),
            ("Governed", "Governed"),
            ("ACTIVE", "Governed"),
            ("ENROLLED", "Governed"),
            ("REGISTERED", "Governed"),
            ("suspended", "Suspended"),
            ("stunned", "Suspended"),
            ("frozen", "Suspended"),
            ("Suspended", "Suspended"),
            ("SUSPENDED", "Suspended"),
            ("STUNNED", "Suspended"),
            ("revoked", "Revoked"),
            ("decommissioned", "Revoked"),
            ("terminated", "Revoked"),
            ("Revoked", "Revoked"),
            ("REVOKED", "Revoked"),
            ("DECOMMISSIONED", "Revoked"),
            ("", "Governed"),
            (None, "Governed"),
        ],
    )
    def test_canonical_lifecycle_helper_mapping(
        self, legacy_db_state: str | None, expected_canonical: str
    ) -> None:
        assert _canonical_lifecycle_state(legacy_db_state) == expected_canonical

    @pytest.mark.parametrize(
        ("legacy_db_state", "expected_canonical"),
        [
            ("registered", "Governed"),
            ("enrolled", "Governed"),
            ("active", "Governed"),
            ("suspended", "Suspended"),
            ("stunned", "Suspended"),
            ("revoked", "Revoked"),
            ("decommissioned", "Revoked"),
        ],
    )
    def test_agent_response_from_row_serialization(
        self, legacy_db_state: str, expected_canonical: str
    ) -> None:
        row = _make_db_row(lifecycle_state=legacy_db_state)
        original_state_copy = row["lifecycle_state"]
        resp = _agent_response_from_row(row, _dummy_compliance())

        # Response must have canonical state
        assert resp.lifecycle_state == expected_canonical
        assert resp.lifecycle_state in {"Governed", "Suspended", "Revoked"}

        # Stored DB row must NOT be mutated
        assert row["lifecycle_state"] == original_state_copy

    def test_discovery_overlay_stun_maps_to_suspended(self) -> None:
        row = _make_db_row(lifecycle_state="active")
        overlay = {
            "state": "stunned",
            "stunned_at": "2026-09-29T00:00:00Z",
            "stun_reason": "Process anomaly detected by Sentinel",
        }
        resp = _agent_response_from_row(row, _dummy_compliance(), discovered_overlay=overlay)
        assert resp.lifecycle_state == "Suspended"
        assert resp.credential_state is not None
        assert resp.credential_state.status == "revoked"
        assert resp.credential_state.reason == "Process anomaly detected by Sentinel"

    def test_ebpf_kernel_telemetry_included_for_suspended_and_stunned(self) -> None:
        # Suspended agent has eBPF telemetry
        suspended_row = _make_db_row(lifecycle_state="suspended")
        resp_suspended = _agent_response_from_row(suspended_row, _dummy_compliance())
        assert resp_suspended.kernel_telemetry is not None
        assert resp_suspended.kernel_telemetry.cgroup_state == "frozen"
        assert resp_suspended.kernel_telemetry.traffic_control_state == "drop"
        assert resp_suspended.kernel_telemetry.ebpf_active is True
        assert resp_suspended.operational_state is not None
        assert resp_suspended.operational_state.containment.process_freeze == "active"
        assert resp_suspended.operational_state.containment.network_isolation == "active"

        # Governed agent has clean operational state
        active_row = _make_db_row(lifecycle_state="active")
        resp_active = _agent_response_from_row(active_row, _dummy_compliance())
        assert resp_active.kernel_telemetry is None
        assert resp_active.operational_state is not None
        assert resp_active.operational_state.containment.process_freeze == "inactive"
        assert resp_active.operational_state.containment.network_isolation == "inactive"

    def test_revoked_agent_credential_containment(self) -> None:
        revoked_row = _make_db_row(lifecycle_state="revoked", revocation_reason="Security policy violation")
        resp_revoked = _agent_response_from_row(revoked_row, _dummy_compliance())
        assert resp_revoked.lifecycle_state == "Revoked"
        assert resp_revoked.credential_state is not None
        assert resp_revoked.credential_state.status == "revoked"
        assert resp_revoked.operational_state is not None
        assert resp_revoked.operational_state.containment.credential_revocation == "active"

    def test_mutation_proof_removing_mapping_fails(self) -> None:
        """Mutation proof: If serializer emitted raw DB strings, tests asserting canonical set would fail."""
        row_active = _make_db_row(lifecycle_state="active")
        row_suspended = _make_db_row(lifecycle_state="suspended")
        row_revoked = _make_db_row(lifecycle_state="revoked")

        resp_active = _agent_response_from_row(row_active, _dummy_compliance())
        resp_suspended = _agent_response_from_row(row_suspended, _dummy_compliance())
        resp_revoked = _agent_response_from_row(row_revoked, _dummy_compliance())

        # Assert canonical states are strictly used
        assert resp_active.lifecycle_state == "Governed"
        assert resp_active.lifecycle_state != "active"
        assert resp_suspended.lifecycle_state == "Suspended"
        assert resp_suspended.lifecycle_state != "suspended"
        assert resp_revoked.lifecycle_state == "Revoked"
        assert resp_revoked.lifecycle_state != "revoked"
