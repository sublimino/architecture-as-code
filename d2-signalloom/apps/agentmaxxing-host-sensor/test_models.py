"""Unit tests for models and data representations."""
from __future__ import annotations

import datetime
import json
from pathlib import Path
import sys
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
except (ImportError, ValueError):
    from models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )


class ModelsTests(unittest.TestCase):
    """Test suite for data models and schema representations."""

    def test_bounded_process_attributes_valid(self) -> None:
        attrs = BoundedProcessAttributes(
            health_state=HealthState.RUNNING,
            cpu_time_ms=1500,
            resident_memory_bytes=33554432,
            exit_code=None,
            restart_count=0,
            cpu_percent=12.5,
            pid=1234,
            ppid=1,
        )
        self.assertEqual(attrs.health_state, HealthState.RUNNING)
        self.assertEqual(attrs.cpu_time_ms, 1500)
        self.assertEqual(attrs.resident_memory_bytes, 33554432)
        self.assertIsNone(attrs.exit_code)
        self.assertEqual(attrs.restart_count, 0)
        self.assertEqual(attrs.cpu_percent, 12.5)
        self.assertEqual(attrs.pid, 1234)
        self.assertEqual(attrs.ppid, 1)

        export_dict = attrs.to_export_dict()
        self.assertEqual(
            set(export_dict.keys()),
            {"health_state", "cpu_time_ms", "resident_memory_bytes", "exit_code", "restart_count"},
        )

    def test_bounded_process_attributes_validation_errors(self) -> None:
        with self.assertRaises(ValueError):
            BoundedProcessAttributes(health_state="invalid_state", cpu_time_ms=10, resident_memory_bytes=10)

        with self.assertRaises(ValueError):
            BoundedProcessAttributes(health_state=HealthState.RUNNING, cpu_time_ms=-1, resident_memory_bytes=10)

        with self.assertRaises(ValueError):
            BoundedProcessAttributes(health_state=HealthState.RUNNING, cpu_time_ms=10, resident_memory_bytes=-5)

    def test_process_telemetry_event_serialization(self) -> None:
        now_str = "2026-09-13T18:00:00Z"
        attrs = BoundedProcessAttributes(
            health_state=HealthState.RUNNING,
            cpu_time_ms=250,
            resident_memory_bytes=16777216,
            exit_code=None,
            restart_count=1,
        )
        event = ProcessTelemetryEvent(
            session_id="session-001",
            sequence=3,
            observed_at=now_str,
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
            tenant_id="tenant-agentmaxxing",
            attributes=attrs,
            integrity_state=IntegrityState.NOT_VERIFIED,
        )

        data = event.to_dict(include_tenant=True)
        self.assertEqual(data["schema_version"], "1.0.0")
        self.assertEqual(data["session_id"], "session-001")
        self.assertEqual(data["sequence"], 3)
        self.assertEqual(data["source"], "host-sensor-v1")
        self.assertEqual(data["evidence_type"], "process")
        self.assertEqual(data["observation_state"], "observed")
        self.assertEqual(data["integrity_state"], "not-integrity-verified")
        self.assertEqual(data["tenant_id"], "tenant-agentmaxxing")
        self.assertEqual(data["agent_id"], "agentmaxxing-linux-001")
        self.assertEqual(data["host_id"], "amx-host-001")
        self.assertEqual(
            data["attributes"],
            {
                "health_state": "running",
                "cpu_time_ms": 250,
                "resident_memory_bytes": 16777216,
                "exit_code": None,
                "restart_count": 1,
            },
        )

        json_str = event.to_json(include_tenant=True)
        parsed = json.loads(json_str)
        self.assertEqual(parsed, data)

        # Roundtrip from_dict
        reconstructed = ProcessTelemetryEvent.from_dict(parsed)
        self.assertEqual(reconstructed.session_id, event.session_id)
        self.assertEqual(reconstructed.sequence, event.sequence)
        self.assertEqual(reconstructed.attributes.health_state, event.attributes.health_state)

    def test_process_telemetry_event_validation_errors(self) -> None:
        attrs = BoundedProcessAttributes(
            health_state=HealthState.RUNNING,
            cpu_time_ms=100,
            resident_memory_bytes=1000,
        )
        with self.assertRaises(ValueError):
            # Invalid session_id pattern
            ProcessTelemetryEvent(
                session_id="!!bad!!",
                sequence=0,
                observed_at="2026-09-13T18:00:00Z",
                agent_id="agent-1",
                host_id="host-1",
                attributes=attrs,
            )

        with self.assertRaises(ValueError):
            # Invalid timestamp
            ProcessTelemetryEvent(
                session_id="sess-001",
                sequence=0,
                observed_at="invalid-date",
                agent_id="agent-1",
                host_id="host-1",
                attributes=attrs,
            )


if __name__ == "__main__":
    unittest.main()
