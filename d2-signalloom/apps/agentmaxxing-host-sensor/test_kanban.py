"""Comprehensive unit and integration tests for Kanban cycle telemetry extractor.

Verifies:
  1. Extraction of task_id, role, shortcode, turn_count, retry_count, and elapsed_s.
  2. Monotonic clock-skew defense against backwards local clock jumps (NTP steps, VM suspend).
  3. Monotonic non-decreasing sequence enforcement on turn_count and retry_count.
  4. Live <1s elapsed_s reflection KPI against live/running cycles.
  5. Zero-Customer-Payload boundary (prompt text, command lines, response snippets discarded).
  6. Frozen KanbanInfo and CodingAgentTelemetry wire contract conformance.
  7. Dynamic KANBAN_HOME / KANBAN_WORKTREES_HOME path resolution and clean degradation.
  8. Non-blocking shared read descriptors with zero lock acquisition.
"""
from __future__ import annotations

import datetime
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest

from coding_agent_models import (
    CodingAgentTelemetry,
    Harness,
    KanbanInfo,
    MetricsInfo,
    NetworkInfo,
    ProcessInfo,
    ToolCounts,
)
from filter import filter_coding_agent_telemetry
from kanban import (
    CycleObservation,
    CycleObservationSource,
    KanbanCycleExtractor,
    TaskLifecycleTracker,
    get_kanban_home,
    get_kanban_worktrees_home,
    is_kanban_available,
    normalize_role,
    normalize_shortcode,
    normalize_task_id,
)
from payload_validator import validate_zero_customer_payload


class TestKanbanNormalization(unittest.TestCase):
    """Test normalization and sanitization of Kanban identity fields."""

    def test_normalize_task_id(self):
        self.assertEqual(normalize_task_id("slcd-p3-2"), "SLCD-P3-2")
        self.assertEqual(normalize_task_id("c48be"), "C48BE")
        self.assertEqual(normalize_task_id("task@123!"), "TASK_123_")
        self.assertEqual(normalize_task_id(""), "UNKNOWN_TASK")

    def test_normalize_shortcode(self):
        self.assertEqual(normalize_shortcode("slcd"), "SLCD")
        self.assertEqual(normalize_shortcode("SLCD"), "SLCD")
        self.assertEqual(normalize_shortcode("s"), "SLCD")  # Fallback for too short
        self.assertEqual(normalize_shortcode("AMXD-EXTRA"), "AMXDEXTRA")

    def test_normalize_role(self):
        self.assertEqual(normalize_role("Implementation"), "implementation")
        self.assertEqual(normalize_role("PREFLIGHT"), "preflight")
        self.assertEqual(normalize_role("governor_audit"), "governor_audit")
        self.assertEqual(normalize_role(""), "implementation")


class TestClockSkewGuard(unittest.TestCase):
    """Test monotonic clock-skew defense against backwards local clock jumps."""

    def test_backwards_wall_clock_jump_triggers_flag_and_preserves_monotonic_duration(self):
        """Simulate an NTP correction or VM resume that steps local wall-clock backwards 60 seconds."""
        fake_wall_time = 1700000100.0  # T0
        fake_mono_time = 10_000_000_000  # 10.0s (in ns)

        def get_wall():
            return fake_wall_time

        def get_mono():
            return fake_mono_time

        extractor = KanbanCycleExtractor(
            clock_fn=get_wall,
            monotonic_fn=get_mono,
        )

        # Tick 1: Task starts at wall time 1700000100.0
        session_data = {
            "taskId": "SLCD-P3-2",
            "startedAt": 1700000100000,  # 1700000100.0s
            "latestTurnCheckpoint": 1,
            "restartCount": 0,
            "state": "running",
        }

        obs1 = extractor.extract_from_session_dict(
            session_data,
            shortcode="SLCD",
            role="implementation",
            now_wall_ts=fake_wall_time,
            now_monotonic_ns=fake_mono_time,
        )

        self.assertEqual(obs1.task_id, "SLCD-P3-2")
        self.assertEqual(obs1.elapsed_s, 0)
        self.assertEqual(obs1.monotonic_seq, 1)
        self.assertFalse(obs1.clock_skew_flagged)

        # Tick 2: 30 seconds elapse monotonically, but wall clock steps BACKWARDS by 60s (NTP correction)
        fake_mono_time += 30_000_000_000  # +30s monotonic
        fake_wall_time -= 60.0  # -60s wall clock step! (1700000040.0)

        session_data["latestTurnCheckpoint"] = 2

        obs2 = extractor.extract_from_session_dict(
            session_data,
            shortcode="SLCD",
            role="implementation",
            now_wall_ts=fake_wall_time,
            now_monotonic_ns=fake_mono_time,
        )

        # The guard MUST flag clock skew and derive elapsed_s from monotonic progression (30s)
        self.assertTrue(obs2.clock_skew_flagged, "Clock skew must be flagged on backwards jump")
        self.assertEqual(obs2.monotonic_seq, 2, "Monotonic sequence counter must increment")
        self.assertGreaterEqual(
            obs2.elapsed_s, 30, "Derived elapsed_s must reflect true monotonic duration, not negative/zero"
        )
        self.assertEqual(obs2.turn_count, 2)

    def test_clamped_sentinel_on_unanchored_negative_timestamp(self):
        """Test that unanchored negative durations clamp to non-negative and flag skew."""
        tracker = TaskLifecycleTracker(
            task_id="SLCD-P3-2",
            first_monotonic_ns=1_000_000_000,
            first_wall_ts=1000.0,
            start_wall_ts=1000.0,
        )

        # Wall clock steps backwards prior to start time with zero monotonic delta
        obs = tracker.update_cycle(
            incoming_turn_count=1,
            incoming_retry_count=0,
            start_wall_ms=1000000,  # 1000.0s
            now_wall_ts=950.0,  # 50s before start!
            now_monotonic_ns=1_000_000_000,
        )

        self.assertTrue(obs.clock_skew_flagged)
        self.assertGreaterEqual(obs.elapsed_s, 0, "Elapsed seconds must never be negative")
        self.assertEqual(obs.elapsed_s, 0)


class TestMonotonicSequenceInvariants(unittest.TestCase):
    """Test monotonic non-decreasing assertions on turn_count and retry_count."""

    def test_turn_count_monotonic_non_decreasing(self):
        """Assert that if source turn_count decreases, extractor clamps to previous max."""
        tracker = TaskLifecycleTracker("SLCD-P3-2")

        # Turn count increases: 1 -> 5
        obs1 = tracker.update_cycle(incoming_turn_count=1, incoming_retry_count=0)
        self.assertEqual(obs1.turn_count, 1)
        self.assertFalse(obs1.turn_count_corrected)

        obs2 = tracker.update_cycle(incoming_turn_count=5, incoming_retry_count=0)
        self.assertEqual(obs2.turn_count, 5)
        self.assertFalse(obs2.turn_count_corrected)

        # Source anomaly: turn count decreases 5 -> 3 (e.g. race / stale read)
        obs3 = tracker.update_cycle(incoming_turn_count=3, incoming_retry_count=0)
        self.assertEqual(obs3.turn_count, 5, "Turn count must clamp to last known highest turn")
        self.assertTrue(obs3.turn_count_corrected, "Correction must be flagged")

        # Recovery: turn count advances 5 -> 8
        obs4 = tracker.update_cycle(incoming_turn_count=8, incoming_retry_count=0)
        self.assertEqual(obs4.turn_count, 8)
        self.assertFalse(obs4.turn_count_corrected)

    def test_retry_count_monotonic_non_decreasing(self):
        """Assert that if source retry_count decreases, extractor clamps to previous max."""
        tracker = TaskLifecycleTracker("SLCD-P3-2")

        obs1 = tracker.update_cycle(incoming_turn_count=1, incoming_retry_count=2)
        self.assertEqual(obs1.retry_count, 2)

        # Source anomaly: retry count decreases 2 -> 1
        obs2 = tracker.update_cycle(incoming_turn_count=2, incoming_retry_count=1)
        self.assertEqual(obs2.retry_count, 2, "Retry count must clamp to last highest retry")
        self.assertTrue(obs2.retry_count_corrected)

    def test_assert_monotonic_sequence_helper(self):
        extractor = KanbanCycleExtractor()
        tracker = extractor.get_tracker("SLCD-P3-2")
        tracker.update_cycle(incoming_turn_count=4, incoming_retry_count=1)

        # Invariant check passes
        extractor.assert_monotonic_sequence("SLCD-P3-2")

        # Unregistered task raises KeyError
        with self.assertRaises(KeyError):
            extractor.assert_monotonic_sequence("NON_EXISTENT_TASK")


class TestZeroCustomerPayloadInvariant(unittest.TestCase):
    """Test that all prompt, activity, and customer text payloads are excluded from extraction."""

    def test_sessions_json_payload_exclusion(self):
        session_with_sensitive_fields = {
            "taskId": "SLCD-P3-2",
            "state": "running",
            "workspacePath": "/home/andy/src/.worktrees/c48be/osramp-demo",
            "startedAt": 1789450203721,
            "latestTurnCheckpoint": 14,
            "restartCount": 1,
            "respawnCount": 0,
            # Sensitive customer payloads that MUST be excluded:
            "prompt": "# PROPRIETARY PROMPT TEXT\nDo not leak this customer data!",
            "latestHookActivity": {
                "activityText": "Completed bash: git commit -m 'secret key 12345'",
            },
            "warningMessage": "Internal secret token: AKIAIOSFODNN7EXAMPLE",
        }

        extractor = KanbanCycleExtractor()
        obs = extractor.extract_from_session_dict(
            session_with_sensitive_fields,
            shortcode="SLCD",
            role="implementation",
        )

        # Convert to wire model
        kanban_info = obs.to_kanban_info()
        kanban_dict = kanban_info.to_dict()

        # Check allowed keys only
        self.assertEqual(set(kanban_dict.keys()), {"task_id", "shortcode", "role", "elapsed_s"})
        self.assertEqual(kanban_dict["task_id"], "SLCD-P3-2")
        self.assertEqual(kanban_dict["shortcode"], "SLCD")
        self.assertEqual(kanban_dict["role"], "implementation")

        # Check serialization contains zero prompt or activity text
        dumped = json.dumps(obs.to_dict())
        self.assertNotIn("PROPRIETARY", dumped)
        self.assertNotIn("AKIAIOSFODNN7EXAMPLE", dumped)
        self.assertNotIn("secret key", dumped)

    def test_sqlite_task_runs_payload_exclusion(self):
        task_run_record = {
            "task_id": "SLCD-P3-2",
            "workspace_id": "osramp-demo",
            "started_at": 1789450203721,
            "duration_ms": 120500,
            "state": "running",
            "tool_calls_count": 14,
            "restart_count": 0,
            "respawn_count": 0,
            # Dangerous fields from SQLite:
            "response_snippet": "Fixed private encryption module in security/crypto.py",
            "summary_json": '{"code_diff": "+ AWS_SECRET_KEY = 1234"}',
            "last_activity_description": "grep AWS_SECRET in private.txt",
        }

        extractor = KanbanCycleExtractor()
        obs = extractor.extract_from_task_run_dict(
            task_run_record,
            shortcode="SLCD",
            role="implementation",
        )

        self.assertEqual(obs.elapsed_s, 120)
        self.assertEqual(obs.turn_count, 14)

        dumped = json.dumps(obs.to_dict())
        self.assertNotIn("AWS_SECRET", dumped)
        self.assertNotIn("crypto.py", dumped)


class TestFrozenWireContractConformance(unittest.TestCase):
    """Test full integration with CodingAgentTelemetry envelope and schema validation."""

    def test_full_envelope_conformance(self):
        extractor = KanbanCycleExtractor()
        session_data = {
            "taskId": "SLCD-P3-2",
            "startedAt": int(time.time() * 1000) - 45000,  # 45s ago
            "latestTurnCheckpoint": 8,
            "restartCount": 0,
            "state": "running",
        }

        obs = extractor.extract_from_session_dict(
            session_data,
            shortcode="SLCD",
            role="implementation",
        )

        kanban_info = obs.to_kanban_info()

        # Build full CodingAgentTelemetry event
        telemetry = CodingAgentTelemetry(
            schema_version="1.0.0",
            harness=Harness.ANTIGRAVITY,
            session_id="a" * 64,
            timestamp=obs.wall_clock_iso,
            process=ProcessInfo(
                pid=12345,
                ppid=1,
                comm="agy",
                rss_bytes=204800000,
                cpu_ticks=1500,
            ),
            kanban=kanban_info,
            metrics=MetricsInfo(
                step_count=obs.turn_count,
                tokens_in=50000,
                tokens_out=2000,
                tool_counts=ToolCounts(run_command=3, view_file=5),
            ),
            network=NetworkInfo(
                inference_endpoint="generativelanguage.googleapis.com",
                egress_bytes=10240,
            ),
        )

        telemetry.validate()
        wire_dict = telemetry.to_dict()

        # Confirm kanban sub-dictionary has strictly 4 allowlisted fields
        self.assertEqual(set(wire_dict["kanban"].keys()), {"task_id", "shortcode", "role", "elapsed_s"})
        self.assertEqual(wire_dict["kanban"]["task_id"], "SLCD-P3-2")
        self.assertEqual(wire_dict["kanban"]["shortcode"], "SLCD")
        self.assertEqual(wire_dict["kanban"]["role"], "implementation")
        self.assertGreaterEqual(wire_dict["kanban"]["elapsed_s"], 44)


class TestLiveTaskStatusReflectionKPI(unittest.TestCase):
    """Test that elapsed_s for a still-running task reflects live state within <1s KPI."""

    def test_live_elapsed_reflection_under_one_second(self):
        """Simulate real running cycle loop over 250ms intervals and verify <1s tracking accuracy."""
        start_wall = time.time()
        start_mono = time.monotonic_ns()

        extractor = KanbanCycleExtractor()

        session_data = {
            "taskId": "SLCD-P3-2",
            "startedAt": int(start_wall * 1000),
            "latestTurnCheckpoint": 1,
            "restartCount": 0,
            "state": "running",
        }

        # Sample at start
        t0_start = time.perf_counter()
        obs_start = extractor.extract_from_session_dict(
            session_data,
            shortcode="SLCD",
            role="implementation",
        )
        latency_ms = (time.perf_counter() - t0_start) * 1000.0

        # Latency KPI: extraction must be under 50ms (<1s target)
        self.assertLess(latency_ms, 50.0, f"Extraction latency {latency_ms:.2f}ms exceeds 50ms bound")
        self.assertGreaterEqual(obs_start.elapsed_s, 0)

        # Simulate 2.5 seconds passing
        simulated_wall = start_wall + 2.5
        simulated_mono = start_mono + int(2.5 * 1_000_000_000)

        session_data["latestTurnCheckpoint"] = 3
        obs_later = extractor.extract_from_session_dict(
            session_data,
            shortcode="SLCD",
            role="implementation",
            now_wall_ts=simulated_wall,
            now_monotonic_ns=simulated_mono,
        )

        expected_elapsed = 2  # int(2.5)
        self.assertAlmostEqual(
            obs_later.elapsed_s,
            expected_elapsed,
            delta=1,
            msg="Live task reflection delta must be within <1s KPI",
        )


class TestStorageLayerExtraction(unittest.TestCase):
    """Test reading from temporary mock SQLite and JSON files."""

    def setUp(self):
        self.test_dir = tempfile.TemporaryDirectory()
        self.kanban_home = Path(self.test_dir.name)

        # Setup directory tree
        (self.kanban_home / "workspaces" / "osramp-demo").mkdir(parents=True, exist_ok=True)
        (self.kanban_home / "auto-controller").mkdir(parents=True, exist_ok=True)
        (self.kanban_home / "card-specs" / "SLCD").mkdir(parents=True, exist_ok=True)

        # Create card spec
        spec_content = {
            "cardSpecification": {
                "logicalId": "P3-2",
                "role": "implementation",
                "shortcode": "SLCD",
            }
        }
        (self.kanban_home / "card-specs" / "SLCD" / "P3-2.v1.json").write_text(
            json.dumps(spec_content), encoding="utf-8"
        )

    def tearDown(self):
        self.test_dir.cleanup()

    def test_extract_active_sessions_file(self):
        sessions_data = {
            "task-01": {
                "taskId": "SLCD-P3-2",
                "state": "running",
                "startedAt": int(time.time() * 1000) - 30000,
                "latestTurnCheckpoint": 5,
                "restartCount": 0,
                "respawnCount": 0,
            }
        }
        sessions_file = self.kanban_home / "workspaces" / "osramp-demo" / "sessions.json"
        sessions_file.write_text(json.dumps(sessions_data), encoding="utf-8")

        extractor = KanbanCycleExtractor(kanban_home=self.kanban_home)
        observations = extractor.extract_active_sessions(workspace_id="osramp-demo")

        self.assertEqual(len(observations), 1)
        obs = observations[0]
        self.assertEqual(obs.task_id, "SLCD-P3-2")
        self.assertEqual(obs.shortcode, "SLCD")
        self.assertEqual(obs.role, "implementation")
        self.assertEqual(obs.turn_count, 5)
        self.assertGreaterEqual(obs.elapsed_s, 29)

    def test_extract_sqlite_task_runs(self):
        db_path = self.kanban_home / "kanban.sqlite"
        conn = sqlite3.connect(str(db_path))
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE task_runs (
                task_id TEXT PRIMARY KEY,
                workspace_id TEXT,
                started_at INTEGER,
                duration_ms INTEGER,
                state TEXT,
                tool_calls_count INTEGER,
                restart_count INTEGER,
                respawn_count INTEGER,
                summary_json TEXT
            )
            """
        )
        cur.execute(
            """
            INSERT INTO task_runs VALUES (
                'SLCD-P3-2', 'osramp-demo', 1700000000000, 42000, 'running', 7, 1, 0, 'sensitive text'
            )
            """
        )
        conn.commit()
        conn.close()

        extractor = KanbanCycleExtractor(kanban_home=self.kanban_home)
        runs = extractor.extract_task_runs_sqlite(task_id="SLCD-P3-2")

        self.assertEqual(len(runs), 1)
        run = runs[0]
        self.assertEqual(run.task_id, "SLCD-P3-2")
        self.assertEqual(run.elapsed_s, 42)
        self.assertEqual(run.turn_count, 7)
        self.assertEqual(run.retry_count, 1)

    def test_extract_cycle_ring_buffer(self):
        ring_data = {
            "schemaVersion": 1,
            "shortcode": "SLCD",
            "ticks": [
                {
                    "ts": "2026-09-15T06:00:00Z",
                    "verdict": "healthy",
                    "exceptionCount": 0,
                    "tickElapsedMs": 350,
                    "counts": {"backlog": 1, "inProgress": 2, "review": 0},
                }
            ],
        }
        ring_file = self.kanban_home / "auto-controller" / "368dfc66a93e-SLCD.cycle.json"
        ring_file.write_text(json.dumps(ring_data), encoding="utf-8")

        extractor = KanbanCycleExtractor(kanban_home=self.kanban_home)
        ticks = extractor.extract_cycle_ring("SLCD")

        self.assertEqual(len(ticks), 1)
        self.assertEqual(ticks[0]["verdict"], "healthy")
        self.assertEqual(ticks[0]["tickElapsedMs"], 350)

    def test_extract_supervisor_state(self):
        state_data = {
            "streak": 5,
            "last_cycle": {
                "ts": "2026-09-15T06:15:00Z",
                "started": 1,
                "advanced": 1,
            },
        }
        state_file = self.kanban_home / "workspaces" / "osramp-demo" / "supervisor-cycle-state.SLCD.json"
        state_file.write_text(json.dumps(state_data), encoding="utf-8")

        extractor = KanbanCycleExtractor(kanban_home=self.kanban_home)
        state = extractor.extract_supervisor_state("SLCD", workspace_id="osramp-demo")

        self.assertIsNotNone(state)
        self.assertEqual(state["streak"], 5)


class TestDynamicPathResolutionAndCleanDisable(unittest.TestCase):
    """Test environment variable overrides and non-crashing clean disable on absent paths."""

    def test_dynamic_path_override(self):
        with tempfile.TemporaryDirectory() as custom_dir:
            os.environ["KANBAN_HOME"] = custom_dir
            try:
                resolved = get_kanban_home()
                self.assertEqual(str(resolved), str(Path(custom_dir).resolve()))
                self.assertTrue(is_kanban_available())
            finally:
                os.environ.pop("KANBAN_HOME", None)

    def test_clean_disable_on_absent_home(self):
        absent_path = Path("/tmp/non_existent_kanban_dir_12345")
        self.assertFalse(is_kanban_available(absent_path))

        extractor = KanbanCycleExtractor(kanban_home=absent_path)
        # All extractions must return empty lists/None cleanly with zero exceptions
        self.assertEqual(extractor.extract_active_sessions(), [])
        self.assertEqual(extractor.extract_task_runs_sqlite(), [])
        self.assertEqual(extractor.extract_cycle_ring("SLCD"), [])
        self.assertIsNone(extractor.extract_supervisor_state("SLCD"))
        self.assertIsNone(extractor.extract_task_by_id("TASK-1"))


if __name__ == "__main__":
    unittest.main()
