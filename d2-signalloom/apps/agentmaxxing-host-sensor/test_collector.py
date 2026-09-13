"""Unit tests for ProcessTelemetryCollector."""
from __future__ import annotations

from pathlib import Path
import sys
import tempfile
from typing import Optional
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cgroups import CgroupV2Reader
    from .collector import ProcessTelemetryCollector
    from .models import HealthState, IntegrityState, ObservationState
    from .proc import ProcReader
except (ImportError, ValueError):
    from cgroups import CgroupV2Reader
    from collector import ProcessTelemetryCollector
    from models import HealthState, IntegrityState, ObservationState
    from proc import ProcReader


class ProcessTelemetryCollectorTests(unittest.TestCase):
    """Test suite for telemetry collection coordination."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_proc = Path(self.temp_dir.name) / "proc"
        self.mock_cgroup = Path(self.temp_dir.name) / "cgroup"
        self.mock_proc.mkdir(parents=True, exist_ok=True)
        self.mock_cgroup.mkdir(parents=True, exist_ok=True)

        self.proc_reader = ProcReader(proc_root=self.mock_proc, page_size=4096, clk_tck=100)
        self.cgroup_reader = CgroupV2Reader(cgroup_root=self.mock_cgroup)
        self.collector = ProcessTelemetryCollector(
            proc_reader=self.proc_reader,
            cgroup_reader=self.cgroup_reader,
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _setup_mock_process(
        self,
        pid: int,
        state: str = "R",
        utime: int = 100,
        stime: int = 50,
        rss_pages: int = 1000,
        cgroup_rel: Optional[str] = None,
        exit_code: Optional[int] = None,
    ) -> None:
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)
        exit_field = f" {exit_code}" if exit_code is not None else ""
        stat_line = (
            f"{pid} (agent) {state} 1 1 1 0 0 4194304 0 0 0 0 "
            f"{utime} {stime} 0 0 20 0 1 0 100000 5000000 {rss_pages} "
            f"0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0{exit_field}"
        )
        (pid_dir / "stat").write_text(stat_line, encoding="utf-8")
        (pid_dir / "statm").write_text(f"2000 {rss_pages} 500 100 0 100 0\n", encoding="utf-8")

        if cgroup_rel:
            (pid_dir / "cgroup").write_text(f"0::{cgroup_rel}\n", encoding="utf-8")

    def test_collect_attributes_from_procfs(self) -> None:
        self._setup_mock_process(200, state="R", utime=200, stime=100, rss_pages=4096)

        attrs = self.collector.collect_attributes(200)
        self.assertEqual(attrs.health_state, HealthState.RUNNING)
        self.assertEqual(attrs.cpu_time_ms, 3000)  # (200+100)*1000/100 = 3000 ms
        self.assertEqual(attrs.resident_memory_bytes, 4096 * 4096)  # 16 MB
        self.assertIsNone(attrs.exit_code)
        self.assertEqual(attrs.restart_count, 0)
        self.assertEqual(attrs.pid, 200)

    def test_collect_attributes_with_cgroups_priority(self) -> None:
        cgroup_dir = self.mock_cgroup / "system.slice" / "agent.service"
        cgroup_dir.mkdir(parents=True, exist_ok=True)
        (cgroup_dir / "cpu.stat").write_text("usage_usec 5000000\n", encoding="utf-8")
        (cgroup_dir / "memory.current").write_text("33554432\n", encoding="utf-8")

        self._setup_mock_process(
            300,
            state="S",
            utime=100,
            stime=50,
            rss_pages=1000,
            cgroup_rel="/system.slice/agent.service",
        )

        attrs = self.collector.collect_attributes(300)
        self.assertEqual(attrs.health_state, HealthState.RUNNING)
        self.assertEqual(attrs.cpu_time_ms, 5000)  # 5,000,000 usec = 5000 ms from cgroup
        # Resident memory uses procfs statm pages (1000 * 4096 = 4096000)
        self.assertEqual(attrs.resident_memory_bytes, 4096000)

    def test_cpu_percent_calculation_over_interval(self) -> None:
        # Sample 1 at t=100.0, cpu=1000 ms
        p1 = self.collector.calculate_cpu_percent(pid=500, current_cpu_time_ms=1000, current_time=100.0)
        self.assertEqual(p1, 0.0)  # First sample is 0.0 baseline

        # Sample 2 at t=101.0 (1 sec later), cpu=1500 ms (500 ms consumed)
        # delta_cpu = 500ms, delta_time = 1000ms -> 50% CPU
        p2 = self.collector.calculate_cpu_percent(pid=500, current_cpu_time_ms=1500, current_time=101.0)
        self.assertEqual(p2, 50.0)

        # Sample 3 at t=102.0, cpu=2500 ms (1000 ms consumed -> 100% CPU)
        p3 = self.collector.calculate_cpu_percent(pid=500, current_cpu_time_ms=2500, current_time=102.0)
        self.assertEqual(p3, 100.0)

    def test_health_state_transitions(self) -> None:
        # 1. Running
        self._setup_mock_process(601, state="R")
        attrs_run = self.collector.collect_attributes(601)
        self.assertEqual(attrs_run.health_state, HealthState.RUNNING)
        self.assertIsNone(attrs_run.exit_code)

        # 2. Stopped (SIGSTOP / tracing stop)
        self._setup_mock_process(602, state="T")
        attrs_stop = self.collector.collect_attributes(602)
        self.assertEqual(attrs_stop.health_state, HealthState.STOPPED)

        # 3. Terminated cleanly with exit code 0
        attrs_exit_clean = self.collector.collect_attributes(9999, override_exit_code=0)
        self.assertEqual(attrs_exit_clean.health_state, HealthState.STOPPED)
        self.assertEqual(attrs_exit_clean.exit_code, 0)

        # 4. Terminated with failure code (e.g. exit 1 or 137)
        attrs_exit_fail = self.collector.collect_attributes(9999, override_exit_code=1)
        self.assertEqual(attrs_exit_fail.health_state, HealthState.FAILED)
        self.assertEqual(attrs_exit_fail.exit_code, 1)

        # 5. Non-existent process without exit code
        attrs_unknown = self.collector.collect_attributes(9999)
        self.assertEqual(attrs_unknown.health_state, HealthState.UNKNOWN)
        self.assertIsNone(attrs_unknown.exit_code)

    def test_collect_event_record_generation(self) -> None:
        self._setup_mock_process(700, state="S", utime=100, stime=20, rss_pages=2000)
        self.collector.set_restart_count(700, 2)

        event = self.collector.collect_event(
            session_id="amxo-sess-700",
            sequence=1,
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
            pid=700,
            tenant_id="tenant-agentmaxxing",
            integrity_verified=True,
            observed_at="2026-09-13T18:30:00Z",
        )

        self.assertEqual(event.session_id, "amxo-sess-700")
        self.assertEqual(event.sequence, 1)
        self.assertEqual(event.observation_state, ObservationState.OBSERVED)
        self.assertEqual(event.integrity_state, IntegrityState.VERIFIED)
        self.assertEqual(event.attributes.restart_count, 2)
        self.assertEqual(event.attributes.health_state, HealthState.RUNNING)


if __name__ == "__main__":
    unittest.main()
