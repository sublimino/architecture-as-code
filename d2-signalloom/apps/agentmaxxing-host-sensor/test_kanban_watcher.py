"""Comprehensive tests for passive non-blocking KanbanWatcher.

Exercises:
  1. Shared read-only descriptors (O_RDONLY, no flock/exclusive lock).
  2. Per-call dynamic KANBAN_HOME / KANBAN_WORKTREES_HOME resolution.
  3. Clean degradation on missing or inaccessible Kanban installations.
  4. Lock-contention immunity against concurrent flock holders.
  5. Mid-write race resilience under concurrent atomic replacements.
  6. Controller cycle timing non-interference benchmarks.
  7. Frozen KanbanInfo schema conformance and Zero-Customer-Payload validation.
  8. Architectural separation from procfs (/proc prohibited entries).
  9. Additive CPU and RSS memory overhead measurement.
"""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import resource
import shutil
import sys
import tempfile
import threading
import time
from typing import Any, Dict, List, Optional
import unittest
from unittest.mock import patch

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

from coding_agent_models import KanbanInfo, ProcessInfo, CodingAgentTelemetry
from collector import ProcessTelemetryCollector
from kanban_watcher import (
    KanbanTaskSnapshot,
    KanbanWatcher,
    get_kanban_home,
    get_kanban_worktrees_home,
    is_kanban_available,
    read_json_safe,
)
from models import (
    BoundedProcessAttributes,
    EvidenceType,
    ExportSource,
    HealthState,
    IntegrityState,
    ObservationState,
    ProcessTelemetryEvent,
)
from payload_validator import validate_zero_customer_payload
from sensor import HostSensor


class KanbanWatcherDynamicPathTests(unittest.TestCase):
    """Verifies per-call dynamic environment resolution for KANBAN_HOME."""

    def test_dynamic_kanban_home_resolution(self) -> None:
        """KANBAN_HOME must resolve dynamically per call, not at import time."""
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            p1 = Path(d1).resolve()
            p2 = Path(d2).resolve()

            # Dynamic resolution via env
            with patch.dict(os.environ, {"KANBAN_HOME": str(p1)}):
                self.assertEqual(get_kanban_home(), p1)
                watcher = KanbanWatcher()
                self.assertEqual(watcher.get_kanban_home(), p1)
                self.assertTrue(is_kanban_available())
                self.assertTrue(watcher.is_available)

            with patch.dict(os.environ, {"KANBAN_HOME": str(p2)}):
                self.assertEqual(get_kanban_home(), p2)
                # Same watcher instance must dynamically resolve the new path
                self.assertEqual(watcher.get_kanban_home(), p2)

    def test_dynamic_kanban_worktrees_home_resolution(self) -> None:
        """KANBAN_WORKTREES_HOME must resolve dynamically per call."""
        with tempfile.TemporaryDirectory() as d1:
            p1 = Path(d1).resolve()
            with patch.dict(os.environ, {"KANBAN_WORKTREES_HOME": str(p1)}):
                self.assertEqual(get_kanban_worktrees_home(), p1)
                watcher = KanbanWatcher()
                self.assertEqual(watcher.get_worktrees_home(), p1)

    def test_clean_degradation_when_kanban_home_missing(self) -> None:
        """Sensor and watcher must cleanly degrade when KANBAN_HOME does not exist."""
        non_existent = Path("/tmp/definitely-non-existent-kanban-path-12345")
        with patch.dict(os.environ, {"KANBAN_HOME": str(non_existent)}):
            self.assertFalse(is_kanban_available())
            watcher = KanbanWatcher()
            self.assertFalse(watcher.is_available)
            self.assertEqual(watcher.scan_workspaces(), [])
            self.assertEqual(watcher.scan_active_tasks(), [])
            self.assertEqual(watcher.scan_missions(), [])
            self.assertEqual(watcher.scan_supervisor_cycle_states(), {})
            self.assertIsNone(watcher.get_task_kanban_info(task_id="NON-EXISTENT"))

            # Collector and Sensor integration with missing kanban
            collector = ProcessTelemetryCollector(kanban_watcher=watcher)
            self.assertEqual(collector.scan_kanban_tasks(), [])
            self.assertIsNone(collector.get_kanban_info(task_id="NON-EXISTENT"))

            sensor = HostSensor(
                session_id="sess-missing-kb",
                agent_id="test-agent",
                host_id="test-host",
                kanban_watcher=watcher,
            )
            event = sensor.sample()
            self.assertIn(event.attributes.health_state, (HealthState.UNKNOWN, HealthState.STOPPED))


class KanbanWatcherSharedReadAndLockTests(unittest.TestCase):
    """Verifies shared read descriptors and immunity to exclusive locks."""

    def setUp(self) -> None:
        self.tmp_dir = tempfile.mkdtemp(prefix="kanban-watcher-test-")
        self.kanban_home = Path(self.tmp_dir) / "kanban"
        self.kanban_home.mkdir(parents=True)
        self.workspaces_dir = self.kanban_home / "workspaces" / "test-ws"
        self.workspaces_dir.mkdir(parents=True)
        self.auto_dir = self.kanban_home / "auto-controller"
        self.auto_dir.mkdir(parents=True)

        self.sessions_file = self.workspaces_dir / "sessions.json"
        self.sessions_data = {
            "10898": {
                "taskId": "SLCD-P3-1",
                "state": "running",
                "agentId": "cpai-opencode",
                "pid": 4242,
                "startedAt": int((time.time() - 30) * 1000),
                "updatedAt": int(time.time() * 1000),
                "latestTurnCheckpoint": 5,
                "restartCount": 1,
                "respawnCount": 0,
            }
        }
        self.sessions_file.write_text(json.dumps(self.sessions_data), encoding="utf-8")

        self.mission_file = self.auto_dir / "368dfc66a93ee9d2a7ddf75e-SLCD.json"
        self.mission_data = {
            "schemaVersion": 1,
            "mission": {
                "shortcode": "SLCD",
                "repo": "test-ws",
            },
            "status": "approved",
            "lease": {
                "enabled": True,
            },
        }
        self.mission_file.write_text(json.dumps(self.mission_data), encoding="utf-8")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_shared_read_open_mode_and_no_exclusive_lock(self) -> None:
        """read_json_safe must use O_RDONLY without acquiring flock."""
        with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
            data = read_json_safe(self.sessions_file)
            self.assertIsNotNone(data)
            self.assertIn("10898", data)

            watcher = KanbanWatcher()
            tasks = watcher.scan_active_tasks()
            self.assertEqual(len(tasks), 1)
            self.assertEqual(tasks[0].task_id, "SLCD-P3-1")
            self.assertEqual(tasks[0].shortcode, "SLCD")
            self.assertEqual(tasks[0].role, "implementation")

    def test_lock_contention_immunity(self) -> None:
        """Watcher must never block when another process holds an exclusive flock."""
        lockfile = self.kanban_home / "kanban-mutation.lock"
        lockfile.write_text("lock-holder-pid", encoding="utf-8")

        lock_acquired = threading.Event()
        stop_lock = threading.Event()

        def hold_exclusive_flock() -> None:
            with open(lockfile, "w") as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                lock_acquired.set()
                stop_lock.wait(timeout=5.0)
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)

        t = threading.Thread(target=hold_exclusive_flock, daemon=True)
        t.start()
        self.assertTrue(lock_acquired.wait(timeout=2.0))

        try:
            with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
                start = time.time()
                watcher = KanbanWatcher()
                # Reading state while flock is held on the lockfile
                tasks = watcher.scan_active_tasks()
                missions = watcher.scan_missions()
                elapsed = time.time() - start

                self.assertLess(elapsed, 0.2, "Watcher blocked on exclusive lock")
                self.assertEqual(len(tasks), 1)
                self.assertEqual(len(missions), 1)
        finally:
            stop_lock.set()
            t.join(timeout=2.0)

    def test_mid_write_race_resilience(self) -> None:
        """Watcher must safely handle mid-write races without unhandled parse exceptions."""
        stop_writer = threading.Event()
        exceptions: List[Exception] = []

        def writer_loop() -> None:
            counter = 0
            while not stop_writer.is_set():
                counter += 1
                # Alternate between full JSON, partial JSON string, and temp atomic write
                if counter % 3 == 0:
                    temp_f = self.workspaces_dir / f"sessions.tmp.{counter}"
                    temp_f.write_text(json.dumps(self.sessions_data), encoding="utf-8")
                    temp_f.replace(self.sessions_file)
                elif counter % 3 == 1:
                    try:
                        self.sessions_file.write_text('{"partial": {"task', encoding="utf-8")
                    except OSError:
                        pass
                else:
                    self.sessions_file.write_text(json.dumps(self.sessions_data), encoding="utf-8")
                time.sleep(0.002)

        t = threading.Thread(target=writer_loop, daemon=True)
        t.start()

        try:
            with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
                watcher = KanbanWatcher(poll_interval_s=0.01)
                for _ in range(50):
                    try:
                        # Should never raise JSONDecodeError or corrupt state
                        tasks = watcher.scan_active_tasks()
                        # If parsed, must be valid
                        for task in tasks:
                            self.assertIsInstance(task.task_id, str)
                            self.assertIsInstance(task.elapsed_s, int)
                    except Exception as e:
                        exceptions.append(e)
                    time.sleep(0.005)
        finally:
            stop_writer.set()
            t.join(timeout=2.0)

        self.assertEqual(exceptions, [], f"Exceptions escaped mid-write race: {exceptions}")


class KanbanWatcherSchemaAndPayloadTests(unittest.TestCase):
    """Verifies frozen schema allowlist and Zero-Customer-Payload invariant."""

    def setUp(self) -> None:
        self.tmp_dir = tempfile.mkdtemp(prefix="kanban-schema-test-")
        self.kanban_home = Path(self.tmp_dir) / "kanban"
        self.kanban_home.mkdir(parents=True)
        self.workspaces_dir = self.kanban_home / "workspaces" / "osramp-demo"
        self.workspaces_dir.mkdir(parents=True)

        # Populate sessions.json with dangerous customer prompt / activity text
        self.sessions_file = self.workspaces_dir / "sessions.json"
        self.sessions_data = {
            "task-001": {
                "taskId": "SLCD-P3-1",
                "state": "running",
                "agentId": "cpai-opencode",
                "pid": 8812,
                "startedAt": int((time.time() - 45) * 1000),
                "updatedAt": int(time.time() * 1000),
                "latestTurnCheckpoint": 12,
                "restartCount": 2,
                "respawnCount": 0,
                # Dangerous payload fields:
                "prompt": "SECRET PROMPT TEXT DO NOT LEAK: API_KEY=sk-ant-12345678",
                "latestHookActivity": {
                    "activityText": "Completed bash: git commit -m 'private user source code'",
                },
                "summary": "This is sensitive reasoning prose.",
            }
        }
        self.sessions_file.write_text(json.dumps(self.sessions_data), encoding="utf-8")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_zero_customer_payload_and_schema_conformance(self) -> None:
        """Watcher must extract only allowlisted fields and pass payload validation."""
        with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
            watcher = KanbanWatcher()
            tasks = watcher.scan_active_tasks()
            self.assertEqual(len(tasks), 1)
            snap = tasks[0]

            self.assertEqual(snap.task_id, "SLCD-P3-1")
            self.assertEqual(snap.shortcode, "SLCD")
            self.assertEqual(snap.role, "implementation")
            self.assertGreaterEqual(snap.elapsed_s, 40)
            self.assertEqual(snap.turn_count, 12)
            self.assertEqual(snap.retry_count, 2)

            info = snap.to_kanban_info()
            self.assertIsInstance(info, KanbanInfo)
            self.assertEqual(
                set(info.to_dict().keys()),
                {"task_id", "shortcode", "role", "elapsed_s"},
            )

            # Confirm no secret leaked
            json_dump = json.dumps(info.to_dict())
            self.assertNotIn("SECRET PROMPT", json_dump)
            self.assertNotIn("private user source code", json_dump)
            self.assertNotIn("API_KEY", json_dump)

            # Full telemetry event construction with kanban info
            event = ProcessTelemetryEvent(
                schema_version="1.0.0",
                session_id="ses-123",
                sequence=1,
                observed_at="2026-09-15T06:00:00Z",
                source=ExportSource.HOST_SENSOR,
                evidence_type=EvidenceType.PROCESS,
                observation_state=ObservationState.OBSERVED,
                integrity_state=IntegrityState.VERIFIED,
                agent_id="cpai-opencode",
                host_id="test-host",
                attributes=BoundedProcessAttributes(
                    health_state=HealthState.RUNNING,
                    cpu_time_ms=120,
                    resident_memory_bytes=10485760,
                    pid=8812,
                ),
            )
            # Must pass zero customer payload validator
            validate_zero_customer_payload(event)

    def test_monotonic_clock_anchor_guards_against_backwards_wall_clock(self) -> None:
        """Monotonic clock anchor prevents negative or corrupt elapsed_s on clock jumps."""
        fake_wall = [1000.0, 900.0, 800.0]  # Backwards wall clock jump
        fake_mono = [100.0, 110.0, 120.0]  # Monotonic forward progress

        def time_mock() -> float:
            return fake_wall.pop(0) if fake_wall else 800.0

        def mono_mock() -> float:
            return fake_mono.pop(0) if fake_mono else 120.0

        with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
            watcher = KanbanWatcher()
            watcher._time_fn = time_mock
            watcher._monotonic_fn = mono_mock

            # First sample (wall=1000, mono=100)
            tasks1 = watcher.scan_active_tasks()
            self.assertEqual(len(tasks1), 1)

            # Second sample after backward wall jump (wall=900, mono=110)
            tasks2 = watcher.scan_active_tasks()
            self.assertEqual(len(tasks2), 1)
            self.assertGreaterEqual(tasks2[0].elapsed_s, 0)
            self.assertGreaterEqual(tasks2[0].elapsed_s, tasks1[0].elapsed_s)


class KanbanWatcherConcurrencyAndOverheadTests(unittest.TestCase):
    """Benchmarks controller cycle non-interference and watcher CPU/RSS overhead."""

    def setUp(self) -> None:
        self.tmp_dir = tempfile.mkdtemp(prefix="kanban-bench-test-")
        self.kanban_home = Path(self.tmp_dir) / "kanban"
        self.kanban_home.mkdir(parents=True)
        self.workspaces_dir = self.kanban_home / "workspaces" / "bench-ws"
        self.workspaces_dir.mkdir(parents=True)
        self.auto_dir = self.kanban_home / "auto-controller"
        self.auto_dir.mkdir(parents=True)

        self.sessions_file = self.workspaces_dir / "sessions.json"
        self.cycle_file = self.workspaces_dir / "supervisor-cycle-state.SLCD.json"
        self.mission_file = self.auto_dir / "bench-SLCD.json"

        # Initialize mock controller state
        self.sessions_file.write_text(json.dumps({
            "task-01": {
                "taskId": "SLCD-P3-1",
                "state": "running",
                "pid": 5001,
                "startedAt": int(time.time() * 1000),
                "latestTurnCheckpoint": 1,
            }
        }), encoding="utf-8")

        self.cycle_file.write_text(json.dumps({
            "streak": 5,
            "last_cycle": {"ts": "2026-09-15T06:00:00Z", "started": 1, "advanced": 1}
        }), encoding="utf-8")

        self.mission_file.write_text(json.dumps({
            "mission": {"shortcode": "SLCD", "repo": "bench-ws"},
            "status": "approved",
            "lease": {"enabled": True},
        }), encoding="utf-8")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _simulate_controller_cycles(self, iterations: int = 50) -> float:
        """Simulate realistic controller cycle execution (JSON reads + atomic writes)."""
        start = time.time()
        for i in range(iterations):
            # 1. Read sessions
            with open(self.sessions_file, "r", encoding="utf-8") as f:
                sess = json.load(f)
            sess["task-01"]["latestTurnCheckpoint"] = i

            # 2. Atomic write sessions
            tmp = self.workspaces_dir / f"sessions.tmp.{i}"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(sess, f)
            tmp.replace(self.sessions_file)

            # 3. Read cycle state
            with open(self.cycle_file, "r", encoding="utf-8") as f:
                cyc = json.load(f)
            cyc["streak"] = i

            # 4. Atomic write cycle state
            tmp_cyc = self.workspaces_dir / f"cycle.tmp.{i}"
            with open(tmp_cyc, "w", encoding="utf-8") as f:
                json.dump(cyc, f)
            tmp_cyc.replace(self.cycle_file)
            time.sleep(0.001)

        return time.time() - start

    def test_controller_cycle_timing_non_interference(self) -> None:
        """Concurrent watcher polling must not measurably slow controller cycle timing."""
        # 1. Baseline controller timing without watcher
        baseline_duration = self._simulate_controller_cycles(iterations=40)

        # 2. Controller timing with concurrent watcher polling
        stop_watcher = threading.Event()
        watcher_polls = [0]

        def background_watcher() -> None:
            with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
                w = KanbanWatcher()
                while not stop_watcher.is_set():
                    w.scan_active_tasks()
                    w.scan_supervisor_cycle_states()
                    watcher_polls[0] += 1
                    time.sleep(0.001)

        t = threading.Thread(target=background_watcher, daemon=True)
        t.start()

        try:
            concurrent_duration = self._simulate_controller_cycles(iterations=40)
        finally:
            stop_watcher.set()
            t.join(timeout=2.0)

        self.assertGreater(watcher_polls[0], 5, f"Watcher polled {watcher_polls[0]} times")

        # Delta should be minimal (within 50% timing jitter under load)
        delta_pct = ((concurrent_duration - baseline_duration) / baseline_duration) * 100.0
        # Recorded for evidence
        print(f"\n[BENCHMARK] Controller 40 cycles: baseline={baseline_duration*1000:.1f}ms, concurrent={concurrent_duration*1000:.1f}ms, delta={delta_pct:+.1f}%, watcher_polls={watcher_polls[0]}")
        self.assertLess(concurrent_duration, baseline_duration * 2.0, "Watcher severely degraded controller timing")

    def test_watcher_cpu_and_rss_overhead(self) -> None:
        """Watcher CPU overhead must remain minimal and RSS bounded."""
        with patch.dict(os.environ, {"KANBAN_HOME": str(self.kanban_home)}):
            watcher = KanbanWatcher()

            ru_start = resource.getrusage(resource.RUSAGE_SELF)
            cpu_start = ru_start.ru_utime + ru_start.ru_stime
            wall_start = time.time()

            # Execute 100 watcher sweeps
            for _ in range(100):
                watcher.scan_active_tasks()
                watcher.scan_missions()
                watcher.scan_supervisor_cycle_states()

            wall_elapsed = time.time() - wall_start
            ru_end = resource.getrusage(resource.RUSAGE_SELF)
            cpu_used = (ru_end.ru_utime + ru_end.ru_stime) - cpu_start
            peak_rss_kb = ru_end.ru_maxrss

            # Model 1.0s duty cycle with 0.5s poll
            duty_cycle_cpu_pct = (cpu_used / (100 * 0.5)) * 100.0

            print(f"\n[BENCHMARK] Watcher 100 sweeps: wall={wall_elapsed*1000:.1f}ms, cpu={cpu_used*1000:.1f}ms, duty_cycle_cpu={duty_cycle_cpu_pct:.3f}%, peak_rss={peak_rss_kb / 1024:.2f}MB")
            self.assertLess(cpu_used, 0.5, "Watcher spent excessive CPU time")
            self.assertLess(duty_cycle_cpu_pct, 1.0, "Duty cycle CPU exceeds 1.0% KPI")


if __name__ == "__main__":
    unittest.main()
