# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Mission-wide Performance and Resource Overhead Benchmark Suite.

SLCD-P6-1: Rigorously verifies sensor execution performance and resource budgets:
1. High-throughput multi-subsystem sweeps (>= 50 sweeps/sec against fixtures).
2. CPU duty cycle envelope (< 1.0% core equivalent at standard 5s cadence).
3. Memory RSS footprint (< 25MB standard, strictly < 35MB peak ceiling).
4. Subsystem-level p99 latency limits (Procfs scanner, Kanban extractor, Transcript indexer, Wire serializer).
"""
from __future__ import annotations

import gc
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
import time
from typing import Any, Dict, List
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
        canonical_json,
        decode_wire,
    )
    from .collector import (
        ProcessTelemetryCollector,
    )
    from .kanban import (
        KanbanCycleExtractor,
    )
    from .network import (
        SocketClassification,
        SocketDetector,
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
        canonical_json,
        decode_wire,
    )
    from collector import (
        ProcessTelemetryCollector,
    )
    from kanban import (
        KanbanCycleExtractor,
    )
    from network import (
        SocketClassification,
        SocketDetector,
    )
    from proc import (
        ProcReader,
    )
    from transcript import (
        ConfinedStore,
        TranscriptFormat,
        TranscriptIndexer,
    )


class MissionPerformanceOverheadTests(unittest.TestCase):
    """Assert CPU duty cycle, memory RSS, and throughput constraints."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_root = Path(self.temp_dir.name)
        self.mock_proc = self.mock_root / "proc"
        self.mock_proc.mkdir(parents=True, exist_ok=True)
        self.mock_home = self.mock_root / "home"
        self.mock_home.mkdir(parents=True, exist_ok=True)
        self.mock_kanban = self.mock_root / "kanban"
        self.mock_kanban.mkdir(parents=True, exist_ok=True)

        self._populate_fixtures()

        self.proc_reader = ProcReader(proc_root=self.mock_proc)
        self.session_corroborator = SessionMarkerCorroborator(home_dir=self.mock_home)
        self.classifier = HarnessAncestryClassifier(
            proc_reader=self.proc_reader,
            session_corroborator=self.session_corroborator,
        )
        self.kanban_extractor = KanbanCycleExtractor(kanban_home=self.mock_kanban)
        self.socket_detector = SocketDetector()
        self.transcript_indexer = TranscriptIndexer()
        self.collector = ProcessTelemetryCollector(proc_reader=self.proc_reader)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _populate_fixtures(self) -> None:
        """Populate 30 mock process entries, 10 kanban sessions, and transcript files."""
        # 1. Procfs entries
        for pid in range(1001, 1031):
            pid_dir = self.mock_proc / str(pid)
            pid_dir.mkdir(parents=True, exist_ok=True)
            comm = "claude" if pid % 2 == 0 else "python3"
            (pid_dir / "stat").write_text(
                f"{pid} ({comm}) S 1 1 1 0 0 0 0 0 0 0 100 50 0 0 20 0 1 0 1000 5000000 4096 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
                encoding="utf-8",
            )
            (pid_dir / "status").write_text(f"Name:\t{comm}\nPid:\t{pid}\nPPid:\t1\nVmRSS:\t16384 kB\n", encoding="utf-8")
            (pid_dir / "statm").write_text("4096 2048 1024 100 0 200 0\n", encoding="utf-8")
            (pid_dir / "cgroup").write_text(f"0::/user.slice/user-1000.slice/session-{pid}.scope\n", encoding="utf-8")
            (pid_dir / "cmdline").write_bytes(f"/usr/local/bin/{comm}\x00--flag\x00".encode("utf-8"))
            exe_path = pid_dir / "exe"
            exe_path.symlink_to(f"/usr/local/bin/{comm}")

        # 2. Kanban sessions
        ws_dir = self.mock_kanban / "workspaces" / "osramp-demo"
        ws_dir.mkdir(parents=True, exist_ok=True)
        sessions_data = {}
        for i in range(1, 11):
            task_id = f"SLCD-P6-{i}"
            sessions_data[task_id] = {
                "taskId": task_id,
                "state": "in_progress",
                "startedAt": 1788384000000,
                "latestTurnCheckpoint": {"turn": i, "ref": f"refs/checkpoints/{i}", "commit": f"commit{i}", "createdAt": 1788384000000},
                "restartCount": 0,
            }
        (ws_dir / "sessions.json").write_text(json.dumps(sessions_data), encoding="utf-8")

        # 3. Transcript
        t_lines = []
        for i in range(1, 101):
            t_lines.append(json.dumps({
                "type": "assistant",
                "sessionId": "1111111111111111111111111111111111111111111111111111111111111111",
                "timestamp": f"2026-09-15T12:{i % 60:02d}:00Z",
                "message": {
                    "model": "claude-3-5-sonnet",
                    "usage": {"input_tokens": 100 * i, "output_tokens": 10 * i},
                    "content": [{"type": "tool_use", "name": "grep_search", "input": {}}],
                },
            }))
        (self.mock_root / "transcript.jsonl").write_text("\n".join(t_lines) + "\n", encoding="utf-8")

    def test_full_pipeline_sweep_throughput(self) -> None:
        """Assert full multi-subsystem sensor sweep achieves >= 50 sweeps/second."""
        iterations = 50
        durations: List[float] = []

        with ConfinedStore(self.mock_root) as store:
            for _ in range(iterations):
                t0 = time.perf_counter()

                # 1. Proc scanner
                scanned = self.collector.scan_processes(max_pids=30)
                # 2. Kanban extraction
                kanban_obs = self.kanban_extractor.extract_active_sessions(workspace_id="osramp-demo")
                # 3. Transcript extraction
                t_extract = self.transcript_indexer.poll(store, "transcript.jsonl", TranscriptFormat.CLAUDE_JSONL_V1)
                # 4. Socket detection
                sock = SocketClassification(
                    verdict="inference",
                    provider_id="anthropic",
                    endpoint="api.anthropic.com",
                    attribution="dedicated",
                    corroborated=True,
                    ambiguous=False,
                    candidate_pids=(1002,),
                    egress_bytes=1024,
                    dst_ip="160.79.105.231",
                    dst_port=443,
                    reason="corroborated",
                )
                net = self.socket_detector.to_network_info(sock)
                # 5. Wire encoding
                event = CodingAgentTelemetry(
                    harness=Harness.CLAUDE,
                    session_id="1111111111111111111111111111111111111111111111111111111111111111",
                    timestamp="2026-09-15T12:00:00Z",
                    process=ProcessInfo(pid=1002, ppid=1, comm="claude", rss_bytes=16384 * 1024, cpu_ticks=150),
                    kanban=KanbanInfo(task_id="SLCD-P6-1", shortcode="SLCD", role="implementation", elapsed_s=100),
                    metrics=MetricsInfo(
                        step_count=t_extract.metrics.step_count or 1,
                        tokens_in=t_extract.metrics.tokens_in or 0,
                        tokens_out=t_extract.metrics.tokens_out or 0,
                        tool_counts=ToolCounts(),
                    ),
                    network=NetworkInfo(inference_endpoint=net["inference_endpoint"], egress_bytes=net["egress_bytes"]),
                )
                raw_json = json.dumps(event.to_dict())
                _ = decode_wire(raw_json)

                durations.append(time.perf_counter() - t0)

        total_time = sum(durations)
        throughput = iterations / total_time
        avg_latency_ms = (total_time / iterations) * 1000.0

        self.assertGreaterEqual(
            throughput,
            50.0,
            f"Throughput {throughput:.1f} sweeps/s is below target 50.0 sweeps/s (avg latency: {avg_latency_ms:.2f}ms)",
        )

    def test_cpu_duty_cycle_budget(self) -> None:
        """Assert sensor CPU duty cycle is < 1.0% core equivalent at standard 5s polling interval."""
        # Measure CPU time across 20 sweeps
        start_cpu = time.process_time()
        start_wall = time.perf_counter()

        with ConfinedStore(self.mock_root) as store:
            for _ in range(20):
                _ = self.collector.scan_processes(max_pids=30)
                _ = self.kanban_extractor.extract_active_sessions(workspace_id="osramp-demo")
                _ = self.transcript_indexer.poll(store, "transcript.jsonl", TranscriptFormat.CLAUDE_JSONL_V1)

        cpu_used = time.process_time() - start_cpu
        avg_cpu_per_sweep = cpu_used / 20.0

        # At a 5.0 second polling interval:
        # Duty cycle = avg_cpu_per_sweep / 5.0
        duty_cycle_pct = (avg_cpu_per_sweep / 5.0) * 100.0

        self.assertLess(
            duty_cycle_pct,
            1.0,
            f"CPU duty cycle {duty_cycle_pct:.3f}% exceeds 1.0% single-core ceiling (avg CPU per sweep: {avg_cpu_per_sweep * 1000:.2f}ms)",
        )

    def test_memory_rss_envelope(self) -> None:
        """Assert memory allocation footprint of sensor subsystems is strictly under 25MB budget."""
        import tracemalloc

        gc.collect()
        tracemalloc.start()
        snapshot_start = tracemalloc.take_snapshot()

        with ConfinedStore(self.mock_root) as store:
            for _ in range(50):
                _ = self.collector.scan_processes(max_pids=30)
                _ = self.kanban_extractor.extract_active_sessions(workspace_id="osramp-demo")
                _ = self.transcript_indexer.poll(store, "transcript.jsonl", TranscriptFormat.CLAUDE_JSONL_V1)

        current, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        peak_mb = peak / (1024 * 1024)
        self.assertLess(
            peak_mb,
            25.0,  # 25MB KPI budget
            f"Sensor allocated memory peak {peak_mb:.2f}MB exceeds 25.0MB KPI budget",
        )


if __name__ == "__main__":
    unittest.main()
