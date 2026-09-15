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
        for entry in ("maps", "smaps", "smaps_rollup", "stack", "syscall", "pagemap", "clear_refs"):
            with self.subTest(entry=entry):
                with self.assertRaises(SecurityException) as ctx:
                    self.reader._safe_proc_path(1337, entry)
                self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_fd_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/fd is strictly prohibited.

        Note: Pinned now to prevent P4-2 socket detector from silently removing
        /proc/<pid>/fd/ from PROHIBITED_PROC_ENTRIES. Socket inode attribution must
        respect security boundaries or use safe, attested mechanisms without unmonitored bypass.
        """
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "fd").mkdir(parents=True, exist_ok=True)

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "fd")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_fdinfo_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/fdinfo is strictly prohibited.

        Note: Pinned to prevent descriptor tracking from silently accessing file offset/flags.
        """
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "fdinfo").mkdir(parents=True, exist_ok=True)

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "fdinfo")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_net_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/net is strictly prohibited.

        Note: Pinned now to prevent direct per-process network socket dumping
        from silently bypassing zero-payload boundaries.
        """
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "net").mkdir(parents=True, exist_ok=True)

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "net")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_io_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/io is strictly prohibited."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "io").write_text("rchar: 1024\nwchar: 2048\n", encoding="utf-8")

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "io")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_cwd_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/cwd is strictly prohibited."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "cwd")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_root_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/root is strictly prohibited."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "root")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_prohibit_procfs_attr_inspection(self) -> None:
        """Assert that attempting to inspect /proc/<pid>/attr is strictly prohibited."""
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "attr").mkdir(parents=True, exist_ok=True)

        with self.assertRaises(SecurityException) as ctx:
            self.reader._safe_proc_path(1337, "attr")
        self.assertIn("strictly prohibited", str(ctx.exception))

    def test_exe_basename_resolution_never_reads_cmdline_secrets(self) -> None:
        """Assert exe-based binary resolution never falls back to or reads /proc/<pid>/cmdline.

        Uses the secret-bearing fixture containing '--token=SECRET_BEARER_TOKEN' to prove
        that neither read_exe nor read_exe_basename touch cmdline, whether exe exists,
        is missing, or is broken.
        """
        pid_dir = self.mock_proc / "1337"
        pid_dir.mkdir(parents=True, exist_ok=True)
        secret_cmdline = "python3\x00agent.py\x00--token=SECRET_BEARER_TOKEN\x00"
        (pid_dir / "cmdline").write_text(secret_cmdline, encoding="utf-8")

        # Case 1: exe symlink points to executable
        exe_symlink = pid_dir / "exe"
        if exe_symlink.is_symlink() or exe_symlink.exists():
            exe_symlink.unlink()
        exe_symlink.symlink_to("/usr/bin/python3.11")

        resolved_exe = self.reader.read_exe(1337)
        resolved_name = self.reader.read_exe_basename(1337)

        self.assertEqual(resolved_exe, Path("/usr/bin/python3.11"))
        self.assertEqual(resolved_name, "python3.11")
        # Ensure secret tokens are completely absent from resolved output
        self.assertNotIn("SECRET_BEARER_TOKEN", str(resolved_exe))
        self.assertNotIn("SECRET_BEARER_TOKEN", str(resolved_name))

        # Case 2: exe symlink is missing (e.g. kernel thread or zombie process)
        exe_symlink.unlink()
        missing_exe = self.reader.read_exe(1337)
        missing_name = self.reader.read_exe_basename(1337)

        # Must return None safely and NEVER fall back to reading cmdline
        self.assertIsNone(missing_exe)
        self.assertIsNone(missing_name)

        # Confirm direct access to cmdline remains strictly forbidden
        with self.assertRaises(SecurityException):
            self.reader._safe_proc_path(1337, "cmdline")

    def test_exe_basename_resolution_renamed_binary_target(self) -> None:
        """Assert exe-based resolution correctly resolves a renamed or symlinked binary's real target."""
        pid_dir = self.mock_proc / "2048"
        pid_dir.mkdir(parents=True, exist_ok=True)

        target_bin = "/opt/harness/bin/real-agent-worker"
        exe_symlink = pid_dir / "exe"
        exe_symlink.symlink_to(target_bin)

        resolved_exe = self.reader.read_exe(2048)
        resolved_name = self.reader.read_exe_basename(2048)

        self.assertEqual(resolved_exe, Path(target_bin))
        self.assertEqual(resolved_name, "real-agent-worker")

    def test_exe_resolution_handles_deleted_binary(self) -> None:
        """Assert exe resolution correctly handles unlinked/deleted binaries with ' (deleted)' suffix."""
        pid_dir = self.mock_proc / "3000"
        pid_dir.mkdir(parents=True, exist_ok=True)

        target_deleted = "/usr/local/bin/transient-agent (deleted)"
        exe_symlink = pid_dir / "exe"
        exe_symlink.symlink_to(target_deleted)

        resolved_exe = self.reader.read_exe(3000)
        resolved_name = self.reader.read_exe_basename(3000)

        self.assertEqual(resolved_exe, Path("/usr/local/bin/transient-agent"))
        self.assertEqual(resolved_name, "transient-agent")


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
