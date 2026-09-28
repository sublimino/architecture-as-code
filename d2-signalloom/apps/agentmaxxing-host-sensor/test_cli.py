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

    def test_cli_enroll_command_success(self) -> None:
        from typing import Any
        fake_response_data = {
            "schema_version": "1.0.0",
            "tenant_id": "tenant-a",
            "agent_id": "agent-test-001",
            "host_id": "amx-host-001",
            "key_id": "key-001",
            "enrollment_state": "enrolled",
            "credential_kind": "existing-mtls-identity",
            "credential_scope": "audit-upload-only",
            "credential_bootstrap": "pre-provisioned-out-of-band",
            "credential_reference": "spiffe://signalloom.demo/ns/eap-tenant-a/sa/agent-agent-test-001",
            "credential_expires_at": "2026-12-25T00:00:00Z",
            "revocation_endpoint": "/v1/external-agents/agent-test-001/revocations",
            "svid_path": "jwt-svid-fetch",
        }

        class FakeHTTPResponse:
            def __init__(self, data: dict) -> None:
                self._bytes = json.dumps(data).encode("utf-8")
            def read(self) -> bytes:
                return self._bytes
            def __enter__(self) -> "FakeHTTPResponse":
                return self
            def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
                pass

        captured_requests = []

        def fake_urlopen(req: Any, timeout: float = 10.0) -> FakeHTTPResponse:
            captured_requests.append(req)
            return FakeHTTPResponse(fake_response_data)

        state_file = Path("/tmp/test_sensor_enrollment.json")
        if state_file.exists():
            state_file.unlink()

        stdout_capture = io.StringIO()
        with patch("urllib.request.urlopen", side_effect=fake_urlopen), patch("sys.stdout", stdout_capture):
            code = main([
                "enroll",
                "--token", "test-enrollment-token-123",
                "--base-url", "http://fake-signalloom:8080",
                "--agent-id", "agent-test-001",
                "--host-id", "amx-host-001",
                "--key-id", "key-001",
                "--tenant-id", "tenant-a",
                "--state-file", str(state_file),
                "--pretty",
            ])

        self.assertEqual(code, 0)
        self.assertEqual(len(captured_requests), 1)
        req = captured_requests[0]
        self.assertEqual(req.full_url, "http://fake-signalloom:8080/api/v1/external-agents/enroll")
        self.assertEqual(req.headers.get("Authorization"), "Bearer test-enrollment-token-123")
        self.assertEqual(req.headers.get("Content-type"), "application/json")

        req_body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(req_body["agent_id"], "agent-test-001")
        self.assertEqual(req_body["host_id"], "amx-host-001")
        self.assertEqual(req_body["tenant_id"], "tenant-a")
        self.assertNotIn("credential_reference", req_body)

        output = stdout_capture.getvalue()
        parsed = json.loads(output)
        self.assertEqual(parsed["credential_reference"], "spiffe://signalloom.demo/ns/eap-tenant-a/sa/agent-agent-test-001")
        self.assertEqual(parsed["svid_path"], "jwt-svid-fetch")

        # Verify state file persistence
        self.assertTrue(state_file.exists())
        saved_state = json.loads(state_file.read_text(encoding="utf-8"))
        self.assertEqual(saved_state["credential_reference"], parsed["credential_reference"])
        state_file.unlink()

    def test_cli_enroll_command_http_error(self) -> None:
        import urllib.error
        from typing import Any

        def fake_urlopen_err(req: Any, timeout: float = 10.0) -> None:
            raise urllib.error.HTTPError(
                url=req.full_url,
                code=422,
                msg="Unprocessable Entity",
                hdrs={},  # type: ignore[arg-type]
                fp=io.BytesIO(b'{"message": "credential_reference is server-issued"}'),
            )

        stderr_capture = io.StringIO()
        with patch("urllib.request.urlopen", side_effect=fake_urlopen_err), patch("sys.stderr", stderr_capture):
            code = main([
                "enroll",
                "--token", "test-token",
                "--base-url", "http://fake-signalloom:8080",
                "--agent-id", "agent-test-001",
            ])
        self.assertEqual(code, 1)
        self.assertIn("HTTP 422", stderr_capture.getvalue())


if __name__ == "__main__":
    unittest.main()
