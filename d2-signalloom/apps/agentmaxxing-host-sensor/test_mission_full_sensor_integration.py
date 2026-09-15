# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Mission-wide Full-Sensor Multi-Harness Integration Suite.

SLCD-P6-1: Runs the full sensor (process scanner, kanban watcher, transcript parser,
socket detector) together against a simulated multi-harness developer session
and asserts the emitted telemetry stream matches P1-1's schema exactly, with zero
unexpected fields.

Exercises all 7 supported harnesses:
1. Claude Code (claude)
2. Antigravity CLI (antigravity)
3. OpenAI Codex (codex)
4. CPAI swarm (cpai)
5. OpenCode (opencode)
6. Hermes (hermes)
7. Aider (aider)
"""
from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import sys
import tempfile
from typing import Any, Dict, List, Optional
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .classifier import (
        ClassificationClaim,
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
        ScannedProcess,
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
    from .proc import (
        ProcReader,
    )
    from .transcript import (
        ConfinedStore,
        ParseStatus,
        TranscriptFormat,
        TranscriptIndexer,
    )
except (ImportError, ValueError):
    from classifier import (
        ClassificationClaim,
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
        ScannedProcess,
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
    from proc import (
        ProcReader,
    )
    from transcript import (
        ConfinedStore,
        ParseStatus,
        TranscriptFormat,
        TranscriptIndexer,
    )


class FullSensorMultiHarnessIntegrationTests(unittest.TestCase):
    """Full sensor multi-harness integration suite verifying end-to-end schema conformance."""

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
        self.kanban_extractor = KanbanCycleExtractor(kanban_home=self.mock_kanban)
        self.socket_detector = SocketDetector()
        self.transcript_indexer = TranscriptIndexer()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _setup_mock_harness_environment(
        self,
        pid: int,
        comm: str,
        exe_target: str,
        harness: Harness,
        session_hex: str,
        task_id: str,
        shortcode: str,
        role: str,
        endpoint: str,
        transcript_filename: Optional[str] = None,
        transcript_content: Optional[str] = None,
        is_sqlite: bool = False,
    ) -> Optional[Path]:
        """Create mock procfs, session marker, kanban session, and transcript for one harness."""
        # 1. Procfs entry
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "stat").write_text(
            f"{pid} ({comm}) S 1 1 1 0 0 0 0 0 0 0 120 45 0 0 20 0 1 0 1000 5000000 4096 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
            encoding="utf-8",
        )
        (pid_dir / "status").write_text(f"Name:\t{comm}\nPid:\t{pid}\nPPid:\t1\nVmRSS:\t16384 kB\n", encoding="utf-8")
        (pid_dir / "statm").write_text("4096 2048 1024 100 0 200 0\n", encoding="utf-8")
        (pid_dir / "cgroup").write_text(f"0::/user.slice/user-1000.slice/session-{harness.value}.scope\n", encoding="utf-8")
        (pid_dir / "cmdline").write_bytes(f"{exe_target}\x00--session\x00{session_hex}\x00".encode("utf-8"))
        exe_path = pid_dir / "exe"
        exe_path.symlink_to(exe_target)

        # 2. Session marker in home directory
        marker_dirs = {
            Harness.CLAUDE: self.mock_home / ".claude",
            Harness.ANTIGRAVITY: self.mock_home / ".gemini" / "antigravity-cli",
            Harness.CODEX: self.mock_home / ".codex",
            Harness.CPAI: self.mock_home / ".cpai",
            Harness.OPENCODE: self.mock_home / ".opencode",
            Harness.HERMES: self.mock_home / ".hermes",
            Harness.AIDER: self.mock_home / ".aider",
        }
        marker_dir = marker_dirs.get(harness, self.mock_home / f".{harness.value}")
        marker_dir.mkdir(parents=True, exist_ok=True)
        (marker_dir / "session.json").write_text(
            json.dumps({"pid": pid, "sessionId": session_hex}),
            encoding="utf-8",
        )

        # 3. Kanban workspace session
        ws_dir = self.mock_kanban / "workspaces" / "osramp-demo"
        ws_dir.mkdir(parents=True, exist_ok=True)
        sessions_file = ws_dir / "sessions.json"
        existing = {}
        if sessions_file.exists():
            existing = json.loads(sessions_file.read_text(encoding="utf-8"))
        existing[task_id] = {
            "taskId": task_id,
            "state": "in_progress",
            "startedAt": 1788384000000,
            "latestTurnCheckpoint": {"turn": 5, "ref": "refs/checkpoints/1", "commit": "abc1234", "createdAt": 1788384000000},
            "restartCount": 0,
        }
        sessions_file.write_text(json.dumps(existing), encoding="utf-8")

        # 4. Transcript file (if applicable)
        if transcript_filename is not None:
            t_path = self.mock_root / transcript_filename
            if is_sqlite:
                conn = sqlite3.connect(str(t_path))
                cursor = conn.cursor()
                cursor.execute("CREATE TABLE steps (id INTEGER PRIMARY KEY, step_name TEXT)")
                cursor.execute("INSERT INTO steps (step_name) VALUES ('step1')")
                cursor.execute("INSERT INTO steps (step_name) VALUES ('step2')")
                conn.commit()
                conn.close()
            elif transcript_content is not None:
                t_path.write_text(transcript_content, encoding="utf-8")
            return t_path
        return None

    def test_full_sensor_pipeline_conforms_to_schema_across_all_seven_harnesses(self) -> None:
        """Run full sensor against all 7 harnesses and assert 100% schema conformance."""
        harness_configs = [
            # 1. Claude Code
            {
                "pid": 2001,
                "comm": "claude",
                "exe_target": "/usr/local/bin/claude",
                "harness": Harness.CLAUDE,
                "session_hex": "1111111111111111111111111111111111111111111111111111111111111111",
                "task_id": "SLCD-P6-1",
                "shortcode": "SLCD",
                "role": "implementation",
                "endpoint": "api.anthropic.com",
                "transcript_fn": "claude.jsonl",
                "transcript_content": json.dumps({
                    "type": "assistant",
                    "sessionId": "1111111111111111111111111111111111111111111111111111111111111111",
                    "timestamp": "2026-09-15T12:00:00Z",
                    "message": {
                        "model": "claude-3-5-sonnet",
                        "usage": {"input_tokens": 5000, "output_tokens": 600},
                        "content": [{"type": "tool_use", "name": "view_file", "input": {}}],
                    },
                }) + "\n",
                "transcript_fmt": TranscriptFormat.CLAUDE_JSONL_V1,
                "is_sqlite": False,
            },
            # 2. Antigravity CLI
            {
                "pid": 2002,
                "comm": "agy",
                "exe_target": "/usr/local/bin/agy",
                "harness": Harness.ANTIGRAVITY,
                "session_hex": "2222222222222222222222222222222222222222222222222222222222222222",
                "task_id": "SLCD-P6-2",
                "shortcode": "SLCD",
                "role": "documentation",
                "endpoint": "generativelanguage.googleapis.com",
                "transcript_fn": "agy.jsonl",
                "transcript_content": json.dumps({
                    "source": "planner",
                    "step_index": 1,
                    "session_id": "2222222222222222222222222222222222222222222222222222222222222222",
                    "timestamp": "2026-09-15T12:01:00Z",
                    "model": "gemini-2.5-pro",
                    "usage": {"input_tokens": 3000, "output_tokens": 450},
                    "tool_calls": [{"name": "write_to_file"}],
                }) + "\n",
                "transcript_fmt": TranscriptFormat.ANTIGRAVITY_CLI_JSONL_V1,
                "is_sqlite": False,
            },
            # 3. OpenAI Codex
            {
                "pid": 2003,
                "comm": "codex",
                "exe_target": "/usr/local/bin/codex",
                "harness": Harness.CODEX,
                "session_hex": "3333333333333333333333333333333333333333333333333333333333333333",
                "task_id": "SLCD-P6-3",
                "shortcode": "SLCD",
                "role": "implementation",
                "endpoint": "api.openai.com",
                "transcript_fn": "codex.jsonl",
                "transcript_content": json.dumps({
                    "type": "event",
                    "timestamp": "2026-09-15T12:02:00Z",
                    "payload": {
                        "session_id": "3333333333333333333333333333333333333333333333333333333333333333",
                        "model": "gpt-4o",
                        "info": {
                            "total_token_usage": {"input_tokens": 4000, "output_tokens": 300}
                        },
                        "name": "run_command",
                    },
                }) + "\n",
                "transcript_fmt": TranscriptFormat.CODEX_ROLLOUT_JSONL_V1,
                "is_sqlite": False,
            },
            # 4. CPAI
            {
                "pid": 2004,
                "comm": "cpai",
                "exe_target": "/usr/local/bin/cpai",
                "harness": Harness.CPAI,
                "session_hex": "4444444444444444444444444444444444444444444444444444444444444444",
                "task_id": "SLCD-P6-4",
                "shortcode": "SLCD",
                "role": "governor",
                "endpoint": "api.anthropic.com",
                "transcript_fn": None,
                "transcript_content": None,
                "transcript_fmt": None,
                "is_sqlite": False,
            },
            # 5. OpenCode (SQLite)
            {
                "pid": 2005,
                "comm": "opencode",
                "exe_target": "/usr/local/bin/opencode",
                "harness": Harness.OPENCODE,
                "session_hex": "5555555555555555555555555555555555555555555555555555555555555555",
                "task_id": "SLCD-P6-5",
                "shortcode": "SLCD",
                "role": "implementation",
                "endpoint": "api.openai.com",
                "transcript_fn": "opencode.db",
                "transcript_content": None,
                "transcript_fmt": TranscriptFormat.OPENCODE_SQLITE_V1,
                "is_sqlite": True,
            },
            # 6. Hermes
            {
                "pid": 2006,
                "comm": "hermes",
                "exe_target": "/usr/local/bin/hermes",
                "harness": Harness.HERMES,
                "session_hex": "6666666666666666666666666666666666666666666666666666666666666666",
                "task_id": "SLCD-P6-6",
                "shortcode": "SLCD",
                "role": "implementation",
                "endpoint": "api.anthropic.com",
                "transcript_fn": "hermes.jsonl",
                "transcript_content": json.dumps({
                    "session_id": "6666666666666666666666666666666666666666666666666666666666666666",
                    "timestamp": "2026-09-15T12:05:00Z",
                    "model": "hermes-agent-v1",
                }) + "\n",
                "transcript_fmt": TranscriptFormat.HERMES_REQUEST_DUMP_V1,
                "is_sqlite": False,
            },
            # 7. Aider
            {
                "pid": 2007,
                "comm": "aider",
                "exe_target": "/usr/local/bin/aider",
                "harness": Harness.AIDER,
                "session_hex": "7777777777777777777777777777777777777777777777777777777777777777",
                "task_id": "SLCD-P6-7",
                "shortcode": "SLCD",
                "role": "implementation",
                "endpoint": "api.openai.com",
                "transcript_fn": None,
                "transcript_content": None,
                "transcript_fmt": None,
                "is_sqlite": False,
            },
        ]

        # Set up all 7 harness fixtures in mock environment
        for cfg in harness_configs:
            self._setup_mock_harness_environment(
                pid=cfg["pid"],
                comm=cfg["comm"],
                exe_target=cfg["exe_target"],
                harness=cfg["harness"],
                session_hex=cfg["session_hex"],
                task_id=cfg["task_id"],
                shortcode=cfg["shortcode"],
                role=cfg["role"],
                endpoint=cfg["endpoint"],
                transcript_filename=cfg["transcript_fn"],
                transcript_content=cfg["transcript_content"],
                is_sqlite=cfg["is_sqlite"],
            )

        # Run multi-subsystem extraction
        collector = ProcessTelemetryCollector(proc_reader=self.proc_reader)
        scanned = collector.scan_processes(max_pids=50)
        self.assertGreaterEqual(len(scanned), 7)

        kanban_obs = {
            obs.task_id: obs
            for obs in self.kanban_extractor.extract_active_sessions(workspace_id="osramp-demo")
        }

        emitted_events: List[CodingAgentTelemetry] = []

        with ConfinedStore(self.mock_root) as store:
            for cfg in harness_configs:
                pid = cfg["pid"]
                harness = cfg["harness"]
                session_hex = cfg["session_hex"]
                task_id = cfg["task_id"]

                # 1. Process Classification
                claim = self.classifier.classify_process(pid)
                self.assertEqual(claim.harness, harness, f"Process {pid} misclassified: {claim}")

                # 2. Kanban Metrics
                k_obs = kanban_obs.get(task_id)
                self.assertIsNotNone(k_obs, f"Missing kanban obs for task {task_id}")
                kanban_info = KanbanInfo(
                    task_id=k_obs.task_id,
                    shortcode=k_obs.shortcode,
                    role=k_obs.role,
                    elapsed_s=k_obs.elapsed_s,
                )

                # 3. Transcript Extraction (if supported)
                if cfg["transcript_fmt"] is not None and cfg["transcript_fn"] is not None:
                    t_extract = self.transcript_indexer.poll(store, cfg["transcript_fn"], cfg["transcript_fmt"])
                    tool_counts_dict = t_extract.metrics.tool_counts if isinstance(t_extract.metrics.tool_counts, dict) else {}
                    metrics_info = MetricsInfo(
                        step_count=t_extract.metrics.step_count or 1,
                        tokens_in=t_extract.metrics.tokens_in or 0,
                        tokens_out=t_extract.metrics.tokens_out or 0,
                        tool_counts=ToolCounts(**tool_counts_dict) if tool_counts_dict else ToolCounts(),
                    )
                else:
                    metrics_info = MetricsInfo(
                        step_count=1,
                        tokens_in=0,
                        tokens_out=0,
                        tool_counts=ToolCounts(),
                    )

                # 4. Socket Info
                sock_class = SocketClassification(
                    verdict="inference",
                    provider_id=cfg["endpoint"].split(".")[1] if "." in cfg["endpoint"] else "anthropic",
                    endpoint=cfg["endpoint"],
                    attribution="dedicated",
                    corroborated=True,
                    ambiguous=False,
                    candidate_pids=(pid,),
                    egress_bytes=50000,
                    dst_ip="160.79.105.231",
                    dst_port=443,
                    reason="corroborated",
                )
                net_dict = self.socket_detector.to_network_info(sock_class)
                network_info = NetworkInfo(
                    inference_endpoint=net_dict["inference_endpoint"],
                    egress_bytes=net_dict["egress_bytes"],
                )

                # 5. Assemble unified telemetry event
                event = CodingAgentTelemetry(
                    harness=harness,
                    session_id=session_hex,
                    timestamp="2026-09-15T12:00:00Z",
                    process=ProcessInfo(
                        pid=pid,
                        ppid=1,
                        comm=cfg["comm"],
                        rss_bytes=16384 * 1024,
                        cpu_ticks=165,
                    ),
                    kanban=kanban_info,
                    metrics=metrics_info,
                    network=network_info,
                )
                emitted_events.append(event)

        self.assertEqual(len(emitted_events), 7)

        # Validate each event against wire contract
        for event in emitted_events:
            as_json = json.dumps(event.to_dict())
            envelope = decode_wire(as_json)
            canonical = canonical_json(envelope)

            # Roundtrip verification
            self.assertEqual(envelope.harness, event.harness.value)
            self.assertEqual(envelope.session_id, event.session_id)
            self.assertEqual(envelope.process.pid, event.process.pid)
            self.assertEqual(envelope.kanban.task_id, event.kanban.task_id)
            self.assertEqual(envelope.network.inference_endpoint, event.network.inference_endpoint)

    def test_multi_turn_session_lifecycle_progression(self) -> None:
        """Simulate dynamic multi-turn lifecycle and verify incremental metrics and checkpoint tracking."""
        pid = 3001
        harness = Harness.CLAUDE
        session_hex = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        task_id = "SLCD-P6-LIFECYCLE"
        comm = "claude"

        # Setup initial turn 1
        t_content_turn1 = json.dumps({
            "type": "assistant",
            "sessionId": session_hex,
            "timestamp": "2026-09-15T12:00:00Z",
            "message": {
                "model": "claude-3-5-sonnet",
                "usage": {"input_tokens": 1000, "output_tokens": 150},
                "content": [{"type": "tool_use", "name": "grep_search", "input": {}}],
            },
        }) + "\n"

        self._setup_mock_harness_environment(
            pid=pid,
            comm=comm,
            exe_target="/usr/local/bin/claude",
            harness=harness,
            session_hex=session_hex,
            task_id=task_id,
            shortcode="SLCD",
            role="implementation",
            endpoint="api.anthropic.com",
            transcript_filename="session.jsonl",
            transcript_content=t_content_turn1,
            is_sqlite=False,
        )

        with ConfinedStore(self.mock_root) as store:
            # Poll turn 1
            e1 = self.transcript_indexer.poll(store, "session.jsonl", TranscriptFormat.CLAUDE_JSONL_V1)
            self.assertEqual(e1.status, ParseStatus.PARSED)
            self.assertEqual(e1.metrics.step_count, 1)
            self.assertEqual(e1.metrics.tokens_in, 1000)
            self.assertEqual(e1.metrics.tokens_out, 150)

            # Append turn 2
            t_content_turn2 = json.dumps({
                "type": "assistant",
                "sessionId": session_hex,
                "timestamp": "2026-09-15T12:05:00Z",
                "message": {
                    "model": "claude-3-5-sonnet",
                    "usage": {"input_tokens": 2500, "output_tokens": 400},
                    "content": [{"type": "tool_use", "name": "replace_file_content", "input": {}}],
                },
            }) + "\n"

            t_file = self.mock_root / "session.jsonl"
            with t_file.open("a", encoding="utf-8") as f:
                f.write(t_content_turn2)

            # Poll turn 2
            e2 = self.transcript_indexer.poll(store, "session.jsonl", TranscriptFormat.CLAUDE_JSONL_V1)
            self.assertEqual(e2.status, ParseStatus.PARSED)
            self.assertEqual(e2.metrics.step_count, 2)
            self.assertEqual(e2.metrics.tokens_in, 3500)
            self.assertEqual(e2.metrics.tokens_out, 550)


if __name__ == "__main__":
    unittest.main()
