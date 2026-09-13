"""Unit tests for the agentmaxxing-host-sensor CLI interface."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cli import main
except (ImportError, ValueError):
    from cli import main


class CliTests(unittest.TestCase):
    """Test suite for CLI command handlers."""

    def test_cli_schema_command(self) -> None:
        stdout_capture = io.StringIO()
        with patch("sys.stdout", stdout_capture):
            code = main(["schema"])
        self.assertEqual(code, 0)
        output = stdout_capture.getvalue()
        parsed = json.loads(output)
        self.assertEqual(parsed["title"], "ProcessLifecycleTelemetryV1")

    def test_cli_verify_command(self) -> None:
        stdout_capture = io.StringIO()
        with patch("sys.stdout", stdout_capture):
            code = main(["verify"])
        self.assertEqual(code, 0)
        output = stdout_capture.getvalue()
        self.assertIn("Host Sensor Capabilities Verification", output)
        self.assertIn("SUCCESS", output)

    def test_cli_collect_command(self) -> None:
        my_pid = os.getpid()
        stdout_capture = io.StringIO()
        with patch("sys.stdout", stdout_capture):
            code = main([
                "collect",
                "--pid", str(my_pid),
                "--session-id", "test-session-cli",
                "--tenant-id", "tenant-agentmaxxing",
                "--pretty",
            ])
        self.assertEqual(code, 0)
        output = stdout_capture.getvalue()
        parsed = json.loads(output)
        self.assertEqual(parsed["session_id"], "test-session-cli")
        self.assertEqual(parsed["tenant_id"], "tenant-agentmaxxing")
        self.assertEqual(parsed["evidence_type"], "process")
        self.assertIn("health_state", parsed["attributes"])

    def test_cli_inspect_command(self) -> None:
        my_pid = os.getpid()
        stdout_capture = io.StringIO()
        with patch("sys.stdout", stdout_capture):
            code = main(["inspect", "--pid", str(my_pid), "--json"])
        self.assertEqual(code, 0)
        output = stdout_capture.getvalue()
        parsed = json.loads(output)
        self.assertIn("health_state", parsed)
        self.assertIn("cpu_time_ms", parsed)


if __name__ == "__main__":
    unittest.main()
