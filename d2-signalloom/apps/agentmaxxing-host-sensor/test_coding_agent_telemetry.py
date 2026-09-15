"""Unit, schema conformance, and negative security tests for CodingAgentTelemetry."""
import json
from pathlib import Path
import unittest

from coding_agent_models import (
    CodingAgentTelemetry,
    Harness,
    ProcessInfo,
    KanbanInfo,
    MetricsInfo,
    ToolCounts,
    NetworkInfo,
    CANONICAL_TOOL_KEYS,
    derive_session_pseudonym,
    normalize_tool_name,
)
from filter import (
    AllowlistFilter,
    SubjectObjectionError,
    SubjectObjectionRegistry,
    filter_coding_agent_telemetry,
)


def valid_telemetry_dict():
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
            "task_id": "SLCD-P1-1",
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
                "run_command": 3,
                "write_to_file": 0,
                "replace_file_content": 0,
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


class TestCodingAgentTelemetry(unittest.TestCase):
    def test_valid_event(self):
        data = valid_telemetry_dict()
        event = CodingAgentTelemetry.from_dict(data)
        event.validate()
        self.assertEqual(event.harness, Harness.CLAUDE)
        self.assertEqual(event.process.comm, "claude")
        self.assertEqual(event.metrics.tokens_in, 125000)

        serialized = event.to_json()
        parsed = json.loads(serialized)
        self.assertEqual(parsed["harness"], "claude")
        self.assertEqual(parsed["metrics"]["tool_counts"]["view_file"], 8)

    def test_tool_counts_fixed_arity_and_overflow(self):
        tc = ToolCounts()
        tc.record_tool("view_file", 2)
        tc.record_tool("read_file", 1)
        tc.record_tool("run_command", 4)
        tc.record_tool("grep", 1)
        tc.record_tool("ask_question", 1)

        self.assertEqual(tc.view_file, 3)
        self.assertEqual(tc.run_command, 4)
        self.assertEqual(tc.grep_search, 1)
        self.assertEqual(tc.ask_question, 1)

        # Dynamic MCP server tool names must be routed to other_count
        tc.record_tool("mcp__postgres_db__query_rows", 2)
        tc.record_tool("mcp__github_issues__create", 3)
        tc.record_tool("custom_proprietary_tool", 1)

        self.assertEqual(tc.other_count, 6)

        d = tc.to_dict()
        self.assertEqual(len(d), 14)
        self.assertEqual(set(d.keys()), set(CANONICAL_TOOL_KEYS))

    def test_session_id_pseudonym_derivation(self):
        root_key = b"01234567890123456789012345678901"
        epoch = 1
        tenant_id = "tenant-alpha"
        raw_session_id = "test-session-123"

        pseudo = derive_session_pseudonym(root_key, epoch, tenant_id, raw_session_id)
        expected = "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e"
        self.assertEqual(pseudo, expected)
        self.assertEqual(len(pseudo), 64)

        # Underlength root key raises
        with self.assertRaises(ValueError):
            derive_session_pseudonym(b"short-key", epoch, tenant_id, raw_session_id)

    def test_negative_crafted_10kb_harness_rejected(self):
        data = valid_telemetry_dict()
        data["harness"] = "a" * 10240
        with self.assertRaises(ValueError) as ctx:
            CodingAgentTelemetry.from_dict(data)
        self.assertIn("harness", str(ctx.exception).lower())

    def test_negative_off_enum_harness_rejected(self):
        data = valid_telemetry_dict()
        data["harness"] = "malicious_harness_injection"
        with self.assertRaises(ValueError) as ctx:
            CodingAgentTelemetry.from_dict(data)
        self.assertIn("harness", str(ctx.exception).lower())

    def test_negative_field_bounds(self):
        # Comm too long (>16 chars)
        d1 = valid_telemetry_dict()
        d1["process"]["comm"] = "a" * 17
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d1)

        # Comm with invalid chars (newlines, semicolons)
        d2 = valid_telemetry_dict()
        d2["process"]["comm"] = "claude;cat /etc"
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d2)

        # Task ID too long (>64 chars)
        d3 = valid_telemetry_dict()
        d3["kanban"]["task_id"] = "A" * 65
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d3)

        # Shortcode too short (<2 chars)
        d4 = valid_telemetry_dict()
        d4["kanban"]["shortcode"] = "S"
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d4)

        # Inference endpoint with path/query injection
        d5 = valid_telemetry_dict()
        d5["network"]["inference_endpoint"] = "api.anthropic.com/v1/messages?auth=token"
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d5)

        # Session ID invalid length / characters
        d6 = valid_telemetry_dict()
        d6["session_id"] = "short-session"
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d6)

        d7 = valid_telemetry_dict()
        d7["session_id"] = "g" * 64
        with self.assertRaises(ValueError):
            CodingAgentTelemetry.from_dict(d7)

    def test_negative_prohibited_keys(self):
        prohibited_injections = [
            {"prompt_text": "secret developer prompt"},
            {"completion_text": "sensitive completion"},
            {"file_contents": "def secret_code(): pass"},
            {"cmdline": "curl -H 'Authorization: Bearer secret'"},
            {"credentials": "sk-ant-api-token"},
            {"token": "access-token-value"},
        ]

        for injection in prohibited_injections:
            data = valid_telemetry_dict()
            data.update(injection)
            with self.assertRaises(ValueError) as ctx:
                filter_coding_agent_telemetry(data)
            self.assertIn("Prohibited payload keys", str(ctx.exception))

    def test_art21_objection_rejection(self):
        registry = SubjectObjectionRegistry()
        registry.register("opted-out-agent", reason="GDPR Article 21 Objection")

        data = valid_telemetry_dict()
        data["agent_id"] = "opted-out-agent"

        with self.assertRaises(SubjectObjectionError):
            filter_coding_agent_telemetry(data, objection_registry=registry)

    def test_schema_conformance_allowlist(self):
        schema_path = Path(__file__).resolve().parent / "schemas" / "coding-agent-telemetry.v1.schema.json"
        self.assertTrue(schema_path.exists(), f"Schema file not found at {schema_path}")

        with open(schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)

        # 1. Check envelope properties
        envelope_props = set(schema["properties"].keys())
        expected_envelope = {
            "schema_version",
            "harness",
            "session_id",
            "timestamp",
            "observed_at",
            "tenant_id",
            "agent_id",
            "host_id",
            "process",
            "kanban",
            "metrics",
            "network",
        }
        self.assertEqual(envelope_props, expected_envelope)

        # 2. Check process properties
        proc_props = set(schema["$defs"]["process_info"]["properties"].keys())
        self.assertEqual(proc_props, {"pid", "ppid", "comm", "rss_bytes", "cpu_ticks"})

        # 3. Check kanban properties
        kanban_props = set(schema["$defs"]["kanban_info"]["properties"].keys())
        self.assertEqual(kanban_props, {"task_id", "shortcode", "role", "elapsed_s"})

        # 4. Check metrics properties
        metrics_props = set(schema["$defs"]["metrics_info"]["properties"].keys())
        self.assertEqual(metrics_props, {"step_count", "tokens_in", "tokens_out", "tool_counts"})

        # 5. Check network properties
        network_props = set(schema["$defs"]["network_info"]["properties"].keys())
        self.assertEqual(network_props, {"inference_endpoint", "egress_bytes"})

        # 6. Check tool counts properties match CANONICAL_TOOL_KEYS exactly
        tc_props = set(schema["$defs"]["tool_counts"]["properties"].keys())
        self.assertEqual(tc_props, set(CANONICAL_TOOL_KEYS))

        # 7. Check harness enum in schema matches Python Harness enum
        schema_harness_enum = set(schema["properties"]["harness"]["enum"])
        python_harness_enum = {h.value for h in Harness}
        self.assertEqual(schema_harness_enum, python_harness_enum)


if __name__ == "__main__":
    unittest.main()
