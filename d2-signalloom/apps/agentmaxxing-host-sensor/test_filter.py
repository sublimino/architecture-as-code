"""Unit tests for allowlist filtering and isolation."""
from __future__ import annotations

from pathlib import Path
import sys
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .filter import (
        AllowlistFilter,
        SubjectObjection,
        SubjectObjectionError,
        SubjectObjectionRegistry,
        filter_process_attributes,
        sanitize_evidence_record,
    )
except (ImportError, ValueError):
    from filter import (
        AllowlistFilter,
        SubjectObjection,
        SubjectObjectionError,
        SubjectObjectionRegistry,
        filter_process_attributes,
        sanitize_evidence_record,
    )


class AllowlistFilterTests(unittest.TestCase):
    """Test suite for allowlisting and privacy boundary filtering."""

    def test_filter_process_attributes_drops_disallowed_keys(self) -> None:
        raw = {
            "health_state": "running",
            "cpu_time_ms": 1200,
            "resident_memory_bytes": 1048576,
            "exit_code": None,
            "restart_count": 0,
            "secret_token": "SUPER_SECRET",
            "cmdline": "python3 /agent/run.py --secret=xyz",
            "memory_dump": "0xdeadbeef",
            "environ": "API_KEY=123",
        }
        filtered = filter_process_attributes(raw, include_extended=False)
        self.assertEqual(
            set(filtered.keys()),
            {"health_state", "cpu_time_ms", "resident_memory_bytes", "exit_code", "restart_count"},
        )
        self.assertNotIn("secret_token", filtered)
        self.assertNotIn("cmdline", filtered)
        self.assertNotIn("memory_dump", filtered)
        self.assertNotIn("environ", filtered)

    def test_contains_prohibited_data_detection(self) -> None:
        clean_data = {
            "health_state": "running",
            "cpu_time_ms": 500,
            "resident_memory_bytes": 2048,
            "exit_code": None,
            "restart_count": 0,
        }
        is_bad, keys = AllowlistFilter.contains_prohibited_data(clean_data)
        self.assertFalse(is_bad)
        self.assertEqual(len(keys), 0)

        dirty_data = {
            "attributes": {
                "health_state": "running",
                "cpu_time_ms": 500,
                "resident_memory_bytes": 2048,
                "exit_code": None,
                "restart_count": 0,
                "payload": "customer payload bytes",
            },
            "command": "sh -c 'cat /etc/passwd'",
        }
        is_bad, keys = AllowlistFilter.contains_prohibited_data(dirty_data)
        self.assertTrue(is_bad)
        self.assertIn("key:payload", keys)
        self.assertIn("key:command", keys)

    def test_sanitize_evidence_record(self) -> None:
        raw_event = {
            "schema_version": "1.0.0",
            "session_id": "sess-100",
            "sequence": 0,
            "observed_at": "2026-09-13T18:00:00Z",
            "source": "host-sensor-v1",
            "evidence_type": "process",
            "observation_state": "observed",
            "integrity_state": "not-integrity-verified",
            "agent_id": "agent-100",
            "host_id": "host-100",
            "tenant_id": "tenant-test",
            "raw_nono_record": "FORBIDDEN_RECORD",
            "file_contents": "FORBIDDEN_FILE_CONTENTS",
            "attributes": {
                "health_state": "running",
                "cpu_time_ms": 450,
                "resident_memory_bytes": 8388608,
                "exit_code": None,
                "restart_count": 0,
                "extra_secret": "FORBIDDEN_SECRET",
            },
        }

        sanitized = sanitize_evidence_record(raw_event, include_tenant=True)
        self.assertNotIn("raw_nono_record", sanitized)
        self.assertNotIn("file_contents", sanitized)
        self.assertNotIn("extra_secret", sanitized["attributes"])
        self.assertEqual(
            set(sanitized["attributes"].keys()),
            {"health_state", "cpu_time_ms", "resident_memory_bytes", "exit_code", "restart_count"},
        )

    def test_article21_subject_objection_registry(self) -> None:
        registry = SubjectObjectionRegistry()
        self.assertFalse(registry.is_opted_out("alice@example.com"))

        obj = registry.register("alice@example.com", reason="GDPR Art 21 opt-out")
        self.assertTrue(registry.is_opted_out("alice@example.com"))
        self.assertEqual(obj.subject_id, "alice@example.com")
        self.assertTrue(obj.active)

        # Non-opted out subject remains false
        self.assertFalse(registry.is_opted_out("bob@example.com"))

        # Revocation
        registry.revoke("alice@example.com")
        self.assertFalse(registry.is_opted_out("alice@example.com"))

    def test_article21_filter_event_raises_objection_error(self) -> None:
        registry = SubjectObjectionRegistry()
        registry.register("actor-optout-123", reason="Subject objection")

        raw_event = {
            "schema_version": "1.0.0",
            "session_id": "sess-200",
            "sequence": 1,
            "observed_at": "2026-09-13T19:00:00Z",
            "source": "host-sensor-v1",
            "evidence_type": "process",
            "observation_state": "observed",
            "integrity_state": "not-integrity-verified",
            "actor_id": "actor-optout-123",
            "host_id": "host-100",
            "attributes": {
                "health_state": "running",
                "cpu_time_ms": 100,
                "resident_memory_bytes": 1024,
                "exit_code": None,
                "restart_count": 0,
            },
        }

        with self.assertRaises(SubjectObjectionError) as cm:
            sanitize_evidence_record(raw_event, objection_registry=registry)

        self.assertEqual(cm.exception.subject_id, "actor-optout-123")


if __name__ == "__main__":
    unittest.main()
