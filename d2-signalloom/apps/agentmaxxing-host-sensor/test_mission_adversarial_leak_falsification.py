# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Mission-wide Adversarial Zero-Customer-Payload & Leak Falsification Suite.

SLCD-P6-1: Combines into one cohesive runnable suite:
- P1-2 credential-leak fixtures (API keys, tokens, PEM keys, AWS secrets)
- P4-1 transcript-payload falsification fixtures (prompts, responses, diffs, thinking blocks)
- P2-2 harness-spoofing fixtures (fake process names, deceptive command lines)
- Kanban task prose fixtures (prompts, acceptance criteria, lease prose)
- Socket canary fixtures (raw IPs, destination addresses)

Asserts the Zero-Customer-Payload invariant across EVERY collection surface at once:
processes, kanban, transcripts, sockets, export serialization, and wire encoding.

Includes Enforcement Self-Test: proves that a deliberately reintroduced off-allow-list
field fails validation and is rejected.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
from typing import Any, Dict, List, Optional
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .classifier import (
        HarnessAncestryClassifier,
        SessionMarkerCorroborator,
    )
    from .coding_agent_models import (
        CodingAgentTelemetry,
        Harness,
        KanbanInfo,
        MetricsInfo,
        NetworkInfo,
        ProcessInfo,
        ToolCounts,
    )
    from .coding_agent_wire import (
        WireContractError,
        canonical_json,
        decode_wire,
    )
    from .collector import (
        ProcessTelemetryCollector,
    )
    from .filter import (
        filter_coding_agent_telemetry,
        sanitize_evidence_record,
    )
    from .kanban import (
        KanbanCycleExtractor,
    )
    from .kanban_watcher import (
        KanbanWatcher,
    )
    from .network import (
        InferenceProviderRanges,
        SocketClassification,
        SocketDetector,
    )
    from .payload_validator import (
        CredentialProvider,
        ZeroPayloadSecurityException,
        ZeroPayloadValidator,
    )
    from .proc import (
        ProcReader,
    )
    from .transcript import (
        ConfinedStore,
        TranscriptFormat,
        TranscriptIndexer,
    )
except (ImportError, ValueError):
    from classifier import (
        HarnessAncestryClassifier,
        SessionMarkerCorroborator,
    )
    from coding_agent_models import (
        CodingAgentTelemetry,
        Harness,
        KanbanInfo,
        MetricsInfo,
        NetworkInfo,
        ProcessInfo,
        ToolCounts,
    )
    from coding_agent_wire import (
        WireContractError,
        canonical_json,
        decode_wire,
    )
    from collector import (
        ProcessTelemetryCollector,
    )
    from filter import (
        filter_coding_agent_telemetry,
        sanitize_evidence_record,
    )
    from kanban import (
        KanbanCycleExtractor,
    )
    from kanban_watcher import (
        KanbanWatcher,
    )
    from network import (
        InferenceProviderRanges,
        SocketClassification,
        SocketDetector,
    )
    from payload_validator import (
        CredentialProvider,
        ZeroPayloadSecurityException,
        ZeroPayloadValidator,
    )
    from proc import (
        ProcReader,
    )
    from transcript import (
        ConfinedStore,
        TranscriptFormat,
        TranscriptIndexer,
    )


# ---------------------------------------------------------------------------
# Distinctive adversarial canaries (guaranteed non-overlapping with code tokens)
# ---------------------------------------------------------------------------
CANARY_SENTINEL = "CANARY_SLCD_P6_1_SENTINEL_998877"

# 1. Credential Canaries
CANARY_ANTHROPIC_KEY = "sk-ant-api03-P61SecretAnthropicApiKey99887766554433221100aabbccddeeff"
CANARY_OPENAI_KEY = "sk-proj-P61SecretOpenAIApiKey99887766554433221100aabbccddeeff"
CANARY_GITHUB_PAT = "ghp_P61SecretGitHubPersonalAccessToken9988776655"
CANARY_AWS_KEY = "AKIAIOSFODNN7P61CANARY"
CANARY_AWS_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
CANARY_JWT_BEARER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJjYW5hcnlfcDYxX3VzZXIifQ.CANARY_SIGNATURE_998877"
CANARY_PEM_KEY = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0CANARYRSAKEY99887766554433221100==\n-----END RSA PRIVATE KEY-----"

# 2. Transcript & Prompt Payload Canaries
CANARY_PROMPT_TEXT = f"{CANARY_SENTINEL}-PROMPT: Refactor the OAuth authentication module and bypass MFA validation."
CANARY_RESPONSE_TEXT = f"{CANARY_SENTINEL}-RESPONSE: I have modified auth.go to bypass validation checks on port 8080."
CANARY_DIFF_TEXT = f"{CANARY_SENTINEL}-DIFF: diff --git a/auth.go b/auth.go\n--- a/auth.go\n+++ b/auth.go\n@@ -1 +1 @@\n-bypass=false\n+bypass=true"
CANARY_THINKING_TEXT = f"{CANARY_SENTINEL}-THINKING: The developer is requesting a credential extraction from environment variables."
CANARY_FILE_CONTENT = f"{CANARY_SENTINEL}-FILE: package main\nfunc SensitiveFunction() {{ secret := 'hidden' }}\n"

# 3. Kanban Task Prose Canaries
CANARY_KANBAN_PROSE = f"{CANARY_SENTINEL}-KANBAN: Task objective is to exfiltrate database records to external bucket."

# 4. Socket Destination IP Canary
CANARY_SOCKET_IP = "160.79.105.231"

ALL_CANARIES = [
    CANARY_SENTINEL,
    CANARY_ANTHROPIC_KEY,
    CANARY_OPENAI_KEY,
    CANARY_GITHUB_PAT,
    CANARY_AWS_KEY,
    CANARY_AWS_SECRET,
    CANARY_JWT_BEARER,
    CANARY_PEM_KEY,
    CANARY_PROMPT_TEXT,
    CANARY_RESPONSE_TEXT,
    CANARY_DIFF_TEXT,
    CANARY_THINKING_TEXT,
    CANARY_FILE_CONTENT,
    CANARY_KANBAN_PROSE,
    CANARY_SOCKET_IP,
]


class MissionAdversarialLeakFalsificationTests(unittest.TestCase):
    """Mission-wide adversarial test suite proving zero customer payload leakage across all subsystems."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_root = Path(self.temp_dir.name)
        self.mock_proc = self.mock_root / "proc"
        self.mock_proc.mkdir(parents=True, exist_ok=True)
        self.mock_home = self.mock_root / "home"
        self.mock_home.mkdir(parents=True, exist_ok=True)
        self.mock_kanban = self.mock_root / "kanban"
        self.mock_kanban.mkdir(parents=True, exist_ok=True)

        self.proc_reader = ProcReader(proc_root=self.mock_proc)
        self.session_corroborator = SessionMarkerCorroborator(home_dir=self.mock_home)
        self.classifier = HarnessAncestryClassifier(
            proc_reader=self.proc_reader,
            session_corroborator=self.session_corroborator,
        )
        self.payload_validator = ZeroPayloadValidator()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _scan_for_canaries(self, serialized_output: str) -> List[str]:
        """Check serialized JSON string for any canary occurrence."""
        hits = []
        for canary in ALL_CANARIES:
            if canary in serialized_output:
                hits.append(canary)
        return hits

    def test_process_surface_zero_payload_under_adversarial_cmdline_and_env(self) -> None:
        """Assert process scanner and classifier never leak credentials embedded in cmdline/env."""
        pid = 1010
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)

        # Write deceptive cmdline and environ filled with secrets
        (pid_dir / "cmdline").write_text(
            f"claude\x00--api-key={CANARY_ANTHROPIC_KEY}\x00--token={CANARY_JWT_BEARER}\x00",
            encoding="utf-8",
        )
        (pid_dir / "environ").write_text(
            f"OPENAI_API_KEY={CANARY_OPENAI_KEY}\x00AWS_SECRET_ACCESS_KEY={CANARY_AWS_SECRET}\x00",
            encoding="utf-8",
        )

        # Write safe stat, status, statm
        (pid_dir / "stat").write_text(
            f"{pid} (node) S 1 1 1 0 0 0 0 0 0 0 100 50 0 0 20 0 1 0 1000 5000000 2048 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
            encoding="utf-8",
        )
        (pid_dir / "status").write_text(f"Name:\tnode\nPid:\t{pid}\nPPid:\t1\nVmRSS:\t8192 kB\n", encoding="utf-8")
        (pid_dir / "statm").write_text("2048 1024 512 100 0 200 0\n", encoding="utf-8")

        # Exe points to node
        exe_path = pid_dir / "exe"
        exe_path.symlink_to("/usr/bin/node")

        # Set up session marker
        claude_dir = self.mock_home / ".claude"
        claude_dir.mkdir(parents=True, exist_ok=True)
        (claude_dir / "session.json").write_text(json.dumps({"pid": pid, "sessionId": "ses-001"}), encoding="utf-8")

        collector = ProcessTelemetryCollector(proc_reader=self.proc_reader)
        scanned = collector.scan_processes(max_pids=10)
        telemetry = collector.classify_scanned_processes(scanned)

        for event in telemetry:
            as_json = json.dumps(event)
            hits = self._scan_for_canaries(as_json)
            self.assertEqual(hits, [], f"Process surface leaked canaries: {hits}")

    def test_kanban_surface_zero_payload_under_hostile_prose_and_acceptance_criteria(self) -> None:
        """Assert Kanban cycle extractor never leaks free-text prose or prompts."""
        ws_dir = self.mock_kanban / "workspaces" / "osramp-demo"
        ws_dir.mkdir(parents=True, exist_ok=True)

        hostile_session = {
            "taskId": "SLCD-P6-1",
            "state": "in_progress",
            "startedAt": 1788384000000,
            "prompt": CANARY_PROMPT_TEXT,
            "description": CANARY_KANBAN_PROSE,
            "latestHookActivity": {
                "userPrompt": CANARY_PROMPT_TEXT,
                "diff": CANARY_DIFF_TEXT,
            },
            "latestTurnCheckpoint": {
                "turn": 4,
                "ref": "refs/kanban/checkpoints/P61/turn/4",
                "commit": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
                "createdAt": 1788384000000,
            },
            "restartCount": 0,
        }

        (ws_dir / "sessions.json").write_text(
            json.dumps({"SLCD-P6-1": hostile_session}),
            encoding="utf-8",
        )

        extractor = KanbanCycleExtractor(kanban_home=self.mock_kanban)
        observations = extractor.extract_active_sessions(workspace_id="osramp-demo")

        self.assertEqual(len(observations), 1)
        obs = observations[0]

        # Convert to KanbanInfo and serialize
        kanban_info = KanbanInfo(
            task_id=obs.task_id,
            shortcode=obs.shortcode,
            role=obs.role,
            elapsed_s=obs.elapsed_s,
        )
        as_json = json.dumps(kanban_info.to_dict())
        hits = self._scan_for_canaries(as_json)
        self.assertEqual(hits, [], f"Kanban surface leaked canaries: {hits}")
        self.assertEqual(kanban_info.task_id, "SLCD-P6-1")
        self.assertEqual(kanban_info.shortcode, "SLCD")

    def test_transcript_surface_zero_payload_under_hostile_turns_and_diffs(self) -> None:
        """Assert TranscriptIndexer extracts token counts and tool stats with zero payload bytes."""
        transcript_file = self.mock_root / "claude_session.jsonl"
        records = [
            {
                "type": "user",
                "sessionId": "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b",
                "timestamp": "2026-09-15T12:00:00Z",
                "message": {"content": [{"type": "text", "text": CANARY_PROMPT_TEXT}]},
            },
            {
                "type": "assistant",
                "sessionId": "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b",
                "timestamp": "2026-09-15T12:00:05Z",
                "message": {
                    "role": "assistant",
                    "model": "claude-3-7-sonnet",
                    "usage": {"input_tokens": 1500, "output_tokens": 350},
                    "content": [
                        {"type": "thinking", "thinking": CANARY_THINKING_TEXT},
                        {"type": "text", "text": CANARY_RESPONSE_TEXT},
                        {"type": "tool_use", "name": "view_file", "input": {"path": "auth.go"}},
                        {"type": "tool_use", "name": "replace_file_content", "input": {"diff": CANARY_DIFF_TEXT}},
                    ],
                },
            },
        ]
        transcript_file.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")

        indexer = TranscriptIndexer()
        with ConfinedStore(self.mock_root) as store:
            extract = indexer.poll(store, "claude_session.jsonl", TranscriptFormat.CLAUDE_JSONL_V1)

        self.assertEqual(extract.records_parsed, 2)
        self.assertEqual(extract.metrics.tokens_in, 1500)
        self.assertEqual(extract.metrics.tokens_out, 350)
        self.assertEqual(extract.metrics.step_count, 2)
        tool_counts = extract.metrics.tool_counts
        self.assertEqual(tool_counts.get("view_file"), 1)
        self.assertEqual(tool_counts.get("replace_file_content"), 1)

        # Serialize extract
        as_json = extract.to_json()
        hits = self._scan_for_canaries(as_json)
        self.assertEqual(hits, [], f"Transcript surface leaked canaries: {hits}")

    def test_socket_surface_zero_payload_under_hostile_destination_ips(self) -> None:
        """Assert SocketDetector classifies endpoint domains and never emits raw IP or packet data."""
        detector = SocketDetector()
        classification = SocketClassification(
            verdict="inference",
            provider_id="anthropic",
            endpoint="api.anthropic.com",
            attribution="dedicated",
            corroborated=True,
            ambiguous=False,
            candidate_pids=(1010,),
            egress_bytes=125000,
            dst_ip=CANARY_SOCKET_IP,
            dst_port=443,
            reason="dedicated range",
        )

        net_info = detector.to_network_info(classification)
        self.assertIsNotNone(net_info)
        as_json = json.dumps(net_info)

        hits = self._scan_for_canaries(as_json)
        self.assertEqual(hits, [], f"Socket surface leaked canaries: {hits}")
        self.assertEqual(net_info["inference_endpoint"], "api.anthropic.com")
        self.assertEqual(net_info["egress_bytes"], 125000)

    def test_combined_end_to_end_wire_telemetry_zero_customer_payload(self) -> None:
        """Assert complete CodingAgentTelemetry event serialized over wire carries zero canaries."""
        valid_session_hex = "3f2a1b4c5d6e4f708a9b0c1d2e3f4a5b3f2a1b4c5d6e4f708a9b0c1d2e3f4a5b"
        event = CodingAgentTelemetry(
            harness=Harness.CLAUDE,
            session_id=valid_session_hex,
            timestamp="2026-09-15T12:00:00Z",
            process=ProcessInfo(
                pid=1010,
                ppid=1,
                comm="claude",
                rss_bytes=104857600,
                cpu_ticks=450,
            ),
            kanban=KanbanInfo(
                task_id="SLCD-P6-1",
                shortcode="SLCD",
                role="implementation",
                elapsed_s=120,
            ),
            metrics=MetricsInfo(
                step_count=14,
                tokens_in=125000,
                tokens_out=4200,
                tool_counts=ToolCounts(view_file=8, run_command=3),
            ),
            network=NetworkInfo(
                inference_endpoint="api.anthropic.com",
                egress_bytes=45000,
            ),
        )

        # 1. Event serialization and zero-canary check
        event_dict = event.to_dict()
        event_json = json.dumps(event_dict)
        hits = self._scan_for_canaries(event_json)
        self.assertEqual(hits, [], f"Event JSON output contained canaries: {hits}")

        # 2. Wire decode and canonical json roundtrip
        wire_envelope = decode_wire(event_json)
        canonical_bytes = canonical_json(wire_envelope)
        self.assertEqual(wire_envelope.harness, "claude")
        self.assertEqual(wire_envelope.session_id, valid_session_hex)
        hits_canonical = self._scan_for_canaries(canonical_bytes.decode("utf-8"))
        self.assertEqual(hits_canonical, [], f"Canonical wire bytes contained canaries: {hits_canonical}")

    def test_enforcement_self_test_catches_reintroduced_off_allowlist_field(self) -> None:
        """Enforcement Self-Test 2: Proves this suite actively catches any reintroduced off-allow-list field.

        Deliberately introduces forbidden fields ('user_prompt', 'code_diff', 'customer_payload', 'auth_token')
        and verifies that decode_wire and ZeroPayloadValidator immediately reject them.
        """
        valid_session_hex = "3f2a1b4c5d6e4f708a9b0c1d2e3f4a5b3f2a1b4c5d6e4f708a9b0c1d2e3f4a5b"
        valid_dict = {
            "harness": "claude",
            "session_id": valid_session_hex,
            "timestamp": "2026-09-15T12:00:00Z",
            "process": {
                "pid": 1010,
                "ppid": 1,
                "comm": "claude",
                "rss_bytes": 104857600,
                "cpu_ticks": 450,
            },
            "kanban": {
                "task_id": "SLCD-P6-1",
                "shortcode": "SLCD",
                "role": "implementation",
                "elapsed_s": 120,
            },
            "metrics": {
                "step_count": 14,
                "tokens_in": 125000,
                "tokens_out": 4200,
                "tool_counts": {"view_file": 8, "run_command": 3},
            },
            "network": {
                "inference_endpoint": "api.anthropic.com",
                "egress_bytes": 45000,
            },
        }

        # Case 1: Extra root-level prohibited fields
        for bad_field in ("user_prompt", "code_diff", "customer_payload", "auth_token", "file_contents"):
            mutant = dict(valid_dict)
            mutant[bad_field] = "MALICIOUS_INJECTED_DATA"
            raw_json = json.dumps(mutant)

            # Wire contract must strictly reject undeclared fields
            with self.assertRaises(WireContractError, msg=f"Wire decoder failed to reject off-allowlist field {bad_field}"):
                decode_wire(raw_json)

        # Case 2: Nested prohibited fields inside process / kanban / metrics
        nested_mutations = [
            ("process", "cmdline_raw", "python3 secret.py"),
            ("kanban", "prompt_text", "Refactor auth"),
            ("metrics", "model_response", "Here is the code"),
            ("network", "dst_ip", "160.79.105.231"),
        ]
        for section, bad_field, val in nested_mutations:
            mutant = json.loads(json.dumps(valid_dict))
            mutant[section][bad_field] = val
            raw_json = json.dumps(mutant)

            with self.assertRaises(WireContractError, msg=f"Wire decoder failed to reject nested {section}.{bad_field}"):
                decode_wire(raw_json)

        # Case 3: ZeroPayloadValidator detects credentials even if disguised
        for canary_secret in (CANARY_ANTHROPIC_KEY, CANARY_OPENAI_KEY, CANARY_GITHUB_PAT, CANARY_AWS_SECRET):
            malicious_payload = f'{{"harness":"claude","note":"{canary_secret}"}}'
            report = self.payload_validator.scan_string(malicious_payload)
            self.assertTrue(report.detected, f"Payload validator failed to detect canary {canary_secret}")


if __name__ == "__main__":
    unittest.main()
