"""Negative security tests asserting exclusion of memory dumps, argv secrets, and payload data."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .collector import ProcessTelemetryCollector
    from .filter import (
        ALLOWLISTED_PROCESS_ATTRIBUTES,
        PROHIBITED_EXPORT_KEYS,
        AllowlistFilter,
        sanitize_evidence_record,
    )
    from .models import BoundedProcessAttributes, HealthState, ProcessTelemetryEvent
    from .proc import ProcReader, SecurityException
except (ImportError, ValueError):
    from collector import ProcessTelemetryCollector
    from filter import (
        ALLOWLISTED_PROCESS_ATTRIBUTES,
        PROHIBITED_EXPORT_KEYS,
        AllowlistFilter,
        sanitize_evidence_record,
    )
    from models import BoundedProcessAttributes, HealthState, ProcessTelemetryEvent
    from proc import ProcReader, SecurityException


class NegativeSecurityTests(unittest.TestCase):
    """Negative security test suite for privacy preservation and zero-payload isolation."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_proc = Path(self.temp_dir.name)
        self.reader = ProcReader(proc_root=self.mock_proc)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_prohibit_procfs_memory_inspection(self) -> None:
        """Assert that attempting to read /proc/<pid>/mem raises SecurityException."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "mem").write_bytes(b"\x7fELF_MEMORY_DUMP_SECRET_KEY_12345")

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "mem")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_environ_inspection(self) -> None:
        """Assert that attempting to read /proc/<pid>/environ raises SecurityException."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "environ").write_text("AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE\x00", encoding="utf-8")

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "environ")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_cmdline_inspection(self) -> None:
        """Assert that attempting to read /proc/<pid>/cmdline raises SecurityException."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "cmdline").write_text("python3\x00agent.py\x00--token=SECRET_BEARER_TOKEN\x00", encoding="utf-8")

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "cmdline")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_maps_and_stack_inspection(self) -> None:
        """Assert that memory map and stack inspects are rejected."""
        for entry in ("maps", "smaps", "stack", "syscall", "pagemap", "clear_refs"):
            with self.subTest(entry=entry):
                with self.assertRaises(SecurityException):
                    self.reader._safe_proc_path(1337, entry)

    def test_filter_strips_all_prohibited_keys_from_telemetry_fixture(self) -> None:
        """Assert exclusion of all malicious/secret test fixture values."""
        malicious_fixture = {
            "schema_version": "1.0.0",
            "session_id": "amxo-session-0001",
            "sequence": 7,
            "observed_at": "2026-09-12T18:36:00Z",
            "source": "host-sensor-v1",
            "evidence_type": "process",
            "observation_state": "observed",
            "integrity_state": "not-integrity-verified",
            "tenant_id": "tenant-agentmaxxing",
            "agent_id": "agentmaxxing-linux-001",
            "host_id": "amx-host-001",
            "raw_nono_record": "SECRET-RAW-NONO-RECORD",
            "command": "SECRET-COMMAND-VALUE",
            "path": "SECRET-HOST-PATH",
            "url": "SECRET-NETWORK-URL",
            "error": "SECRET-RAW-ERROR",
            "file_contents": "SECRET-FILE-CONTENTS",
            "memory_contents": "SECRET-MEMORY-CONTENTS",
            "streamed_payload_digest": "SECRET-STREAM-DIGEST",
            "streamed_payload_contents": "SECRET-STREAM-CONTENTS",
            "network_payload_contents": "SECRET-NETWORK-CONTENTS",
            "attributes": {
                "health_state": "running",
                "cpu_time_ms": 241,
                "resident_memory_bytes": 33554432,
                "exit_code": None,
                "restart_count": 0,
                "path": "SECRET-NESTED-PATH",
                "payload": "SECRET-NESTED-PAYLOAD",
                "extra_secret_key": "SECRET-EXTRA-VALUE",
            },
            "prohibited_test_values": [
                "SECRET-RAW-NONO-RECORD",
                "SECRET-COMMAND-VALUE",
                "SECRET-HOST-PATH",
                "SECRET-NETWORK-URL",
                "SECRET-RAW-ERROR",
                "SECRET-FILE-CONTENTS",
                "SECRET-MEMORY-CONTENTS",
                "SECRET-STREAM-DIGEST",
                "SECRET-STREAM-CONTENTS",
                "SECRET-NETWORK-CONTENTS",
                "SECRET-NESTED-PATH",
                "SECRET-NESTED-PAYLOAD",
                "SECRET-EXTRA-VALUE",
            ],
        }

        sanitized = sanitize_evidence_record(malicious_fixture, include_tenant=True)
        serialized = json.dumps(sanitized, sort_keys=True)

        # Assert no prohibited values leak into exported JSON
        for secret_val in malicious_fixture["prohibited_test_values"]:
            self.assertNotIn(secret_val, serialized, f"Prohibited value leaked into export: {secret_val}")

        # Assert only allowed attributes survived
        self.assertEqual(
            set(sanitized["attributes"].keys()),
            ALLOWLISTED_PROCESS_ATTRIBUTES,
        )

        # Assert top-level prohibited keys were removed
        for key in PROHIBITED_EXPORT_KEYS:
            self.assertNotIn(key, sanitized)

    def test_event_object_rejects_arbitrary_nested_fields(self) -> None:
        """Assert that BoundedProcessAttributes refuses unknown parameters."""
        attrs = BoundedProcessAttributes(
            health_state=HealthState.RUNNING,
            cpu_time_ms=100,
            resident_memory_bytes=4096,
        )
        export_dict = attrs.to_export_dict()
        self.assertEqual(
            set(export_dict.keys()),
            {"health_state", "cpu_time_ms", "resident_memory_bytes", "exit_code", "restart_count"},
        )
        # Verify prohibited keys are absent
        for key in PROHIBITED_EXPORT_KEYS:
            self.assertNotIn(key, export_dict)


if __name__ == "__main__":
    unittest.main()
