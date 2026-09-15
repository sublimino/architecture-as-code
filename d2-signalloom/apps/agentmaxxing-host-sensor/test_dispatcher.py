"""Unit and security tests for CodingAgentTelemetryDispatcher (SLCD-P5-1)."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch
import urllib.error

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

import coding_agent_wire as wire
from dispatcher import CodingAgentTelemetryDispatcher, DispatchError
import lawful_basis


def make_valid_raw_event() -> dict:
    return {
        "schema_version": "1.0.0",
        "harness": "claude",
        "session_id": "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e",
        "timestamp": "2026-09-15T02:00:00Z",
        "process": {
            "pid": 1234,
            "ppid": 1,
            "comm": "claude",
            "rss_bytes": 104857600,
            "cpu_ticks": 450,
        },
        "kanban": {
            "task_id": "SLCD-P5-1",
            "shortcode": "SLCD",
            "role": "implementation",
            "elapsed_s": 120,
        },
        "metrics": {
            "step_count": 14,
            "tokens_in": 125000,
            "tokens_out": 4200,
            "tool_counts": {
                "view_file": 8,
                "write_to_file": 2,
                "replace_file_content": 1,
                "run_command": 3,
                "grep_search": 0,
                "find_by_name": 0,
                "list_dir": 0,
                "read_url_content": 0,
                "search_web": 0,
                "invoke_subagent": 0,
                "send_message": 0,
                "manage_task": 0,
                "ask_question": 0,
                "other_count": 0,
            },
        },
        "network": {
            "inference_endpoint": "api.anthropic.com",
            "egress_bytes": 45000,
        },
    }


class TestDispatcher(unittest.TestCase):
    """Test dispatcher lawful-basis gate, encoding, headers, and error handling."""

    def setUp(self) -> None:
        self.dispatcher = CodingAgentTelemetryDispatcher(
            base_url="http://mock-ingest:8082",
            auth_token="test-jwt-svid",
        )

    def test_dispatcher_fails_closed_when_lawful_basis_gate_is_closed(self) -> None:
        """Dispatcher must refuse to transmit when lawful basis is not established."""
        raw_event = make_valid_raw_event()
        with self.assertRaises(lawful_basis.LawfulBasisBlocked) as ctx:
            self.dispatcher.dispatch(raw_event)
        self.assertIn("dispatcher.dispatch", str(ctx.exception))
        self.assertIn("OPEN-SLCD", str(ctx.exception))

    @patch("lawful_basis.workstation_collection_permitted", return_value=True)
    @patch("urllib.request.urlopen")
    def test_dispatcher_sends_wire_contract_when_permitted(
        self, mock_urlopen: MagicMock, mock_gate: MagicMock
    ) -> None:
        """When permitted, dispatcher sends canonical JSON with contract headers."""
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"status": "ingested", "duplicate": False}).encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        raw_event = make_valid_raw_event()
        res = self.dispatcher.dispatch(raw_event)

        self.assertEqual(res["status"], "ingested")
        self.assertFalse(res["duplicate"])

        # Inspect the HTTP request constructed
        self.assertEqual(mock_urlopen.call_count, 1)
        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "http://mock-ingest:8082/api/v1/telemetry/coding-agents")
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.headers["X-signalloom-contract"], "codingagent.v1")
        self.assertEqual(req.headers["Authorization"], "Bearer test-jwt-svid")
        self.assertEqual(req.headers["Content-type"], "application/json")

        # Verify wire body matches canonical JSON
        sent_body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(sent_body["harness"], "claude")
        self.assertEqual(sent_body["session_id"], raw_event["session_id"])

    @patch("lawful_basis.workstation_collection_permitted", return_value=True)
    def test_dispatcher_rejects_unlisted_extra_keys_locally(self, mock_gate: MagicMock) -> None:
        """Unlisted keys (e.g. prompt_text) must be rejected by the local closed-world decoder."""
        raw_event = make_valid_raw_event()
        raw_event["prompt_text"] = "secret prompt payload"

        with self.assertRaises(wire.WireContractError):
            self.dispatcher.dispatch(raw_event)

    @patch("lawful_basis.workstation_collection_permitted", return_value=True)
    @patch("urllib.request.urlopen")
    def test_dispatcher_handles_http_errors(self, mock_urlopen: MagicMock, mock_gate: MagicMock) -> None:
        """HTTP error responses from upstream are converted to DispatchError."""
        mock_err = urllib.error.HTTPError(
            url="http://mock-ingest:8082/api/v1/telemetry/coding-agents",
            code=400,
            msg="Bad Request",
            hdrs=None,
            fp=MagicMock(read=lambda: b'{"error":"bad_request"}'),
        )
        mock_urlopen.side_effect = mock_err

        raw_event = make_valid_raw_event()
        with self.assertRaises(DispatchError) as ctx:
            self.dispatcher.dispatch(raw_event)
        self.assertEqual(ctx.exception.status_code, 400)


if __name__ == "__main__":
    unittest.main()
