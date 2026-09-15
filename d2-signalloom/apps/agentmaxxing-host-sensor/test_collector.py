"""Unit tests for ProcessTelemetryCollector."""
from __future__ import annotations

import ast
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Callable, List, Optional
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cgroups import CgroupV2Reader
    from .coding_agent_models import ProcessInfo
    from .collector import ProcessTelemetryCollector, ScannedProcess
    from .models import BoundedProcessAttributes, HealthState, IntegrityState, ObservationState
    from .proc import PROHIBITED_PROC_ENTRIES, ProcReader, ProcStat
except (ImportError, ValueError):
    from cgroups import CgroupV2Reader
    from collector import ProcessTelemetryCollector, ScannedProcess
    from models import BoundedProcessAttributes, HealthState, IntegrityState, ObservationState
    from proc import PROHIBITED_PROC_ENTRIES, ProcReader, ProcStat
    try:
        from coding_agent_models import ProcessInfo
    except (ImportError, ValueError):
        ProcessInfo = None  # type: ignore


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
        comm: str = "agent",
        state: str = "R",
        ppid: int = 1,
        utime: int = 100,
        stime: int = 50,
        starttime_ticks: int = 100000,
        rss_pages: int = 1000,
        cgroup_rel: Optional[str] = None,
        exit_code: Optional[int] = None,
        exe_target: Optional[str] = None,
    ) -> Path:
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)
        exit_field = f" {exit_code}" if exit_code is not None else ""
        stat_line = (
            f"{pid} ({comm}) {state} {ppid} 1 1 0 0 4194304 0 0 0 0 "
            f"{utime} {stime} 0 0 20 0 1 0 {starttime_ticks} 5000000 {rss_pages} "
            f"0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0{exit_field}"
        )
        (pid_dir / "stat").write_text(stat_line, encoding="utf-8")
        (pid_dir / "statm").write_text(f"2000 {rss_pages} 500 100 0 100 0\n", encoding="utf-8")
        status_text = (
            f"Name:\t{comm}\nState:\t{state} (running)\nPPid:\t{ppid}\n"
            f"VmRSS:\t{rss_pages * 4} kB\nVmSize:\t10000 kB\nThreads:\t1\n"
        )
        (pid_dir / "status").write_text(status_text, encoding="utf-8")

        if cgroup_rel:
            (pid_dir / "cgroup").write_text(f"0::{cgroup_rel}\n", encoding="utf-8")
        if exe_target:
            (pid_dir / "exe").symlink_to(exe_target)
        return pid_dir

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

    def test_scan_processes_mock_full_tree(self) -> None:
        """Assert scanner discovers processes across full procfs mock tree with attribute extraction."""
        self._setup_mock_process(101, comm="claude", utime=200, stime=100, rss_pages=1000, exe_target="/usr/local/bin/claude")
        self._setup_mock_process(102, comm="agy", utime=150, stime=50, rss_pages=2000, exe_target="/usr/local/bin/agy")
        self._setup_mock_process(103, comm="bash", utime=10, stime=5, rss_pages=500, exe_target="/bin/bash")

        # 1. Unfiltered scan discovers all 3 processes
        scanned = self.collector.scan_processes()
        self.assertEqual(len(scanned), 3)
        pids = [s.pid for s in scanned]
        self.assertEqual(pids, [101, 102, 103])

        # Verify attributes on PID 101
        p101 = next(s for s in scanned if s.pid == 101)
        self.assertEqual(p101.comm, "claude")
        self.assertEqual(p101.exe_basename, "claude")
        self.assertEqual(p101.attributes.health_state, HealthState.RUNNING)
        self.assertEqual(p101.attributes.cpu_time_ms, 3000)  # (200+100)*1000/100
        self.assertEqual(p101.attributes.resident_memory_bytes, 1000 * 4096)

        # 2. Candidate filter restricts to coding agent harnesses
        filtered = self.collector.scan_processes(
            candidate_filter=lambda stat, exe: exe in ("claude", "agy") or stat.comm in ("claude", "agy")
        )
        self.assertEqual(len(filtered), 2)
        self.assertEqual([s.pid for s in filtered], [101, 102])

    def test_static_guard_no_cmdline_in_scanner_and_sensor(self) -> None:
        """Static guard asserting that scanner and sensor never reference cmdline in code."""
        prohibited_entry = "cmd" + "line"
        for filename in ("collector.py", "sensor.py"):
            file_path = PKG_DIR / filename
            self.assertTrue(file_path.exists(), f"Expected file {file_path} does not exist")
            content = file_path.read_text(encoding="utf-8")
            self.assertNotIn(prohibited_entry, content, f"Static guard violation: '{prohibited_entry}' found in {filename}")

            tree = ast.parse(content, filename=str(file_path))
            for node in ast.walk(tree):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    self.assertNotIn(prohibited_entry, node.value.lower(), f"String literal violation in {filename}: {node.value}")

    def test_runtime_assertion_zero_prohibited_proc_entries(self) -> None:
        """Runtime assertion confirming zero calls to any PROHIBITED_PROC_ENTRIES across scan path."""
        accessed_entries = set()
        original_safe_proc_path = self.proc_reader._safe_proc_path

        def recording_safe_proc_path(pid: int, entry_name: str) -> Path:
            accessed_entries.add(entry_name)
            return original_safe_proc_path(pid, entry_name)

        self.proc_reader._safe_proc_path = recording_safe_proc_path
        self._setup_mock_process(101, comm="claude", exe_target="/bin/claude")
        self._setup_mock_process(102, comm="agy", exe_target="/bin/agy")

        # Perform scan
        results = self.collector.scan_processes()
        self.assertEqual(len(results), 2)

        # Assert zero intersection with PROHIBITED_PROC_ENTRIES
        prohibited_accessed = accessed_entries.intersection(PROHIBITED_PROC_ENTRIES)
        self.assertEqual(prohibited_accessed, set(), f"Runtime security violation: accessed prohibited entries {prohibited_accessed}")
        # Permitted entries should strictly only be stat, statm, status, exe
        self.assertTrue(accessed_entries.issubset({"stat", "statm", "status", "exe"}))

    def test_permission_denial_skip_cleanly(self) -> None:
        """Assert permission denial on a PID skips cleanly without raising or leaking content."""
        self._setup_mock_process(201, comm="readable_proc")
        # Set up pid 202 with unreadable stat simulating EACCES
        pid_202 = self.mock_proc / "202"
        pid_202.mkdir(parents=True, exist_ok=True)
        stat_file = pid_202 / "stat"
        stat_line = "202 (secret_agent) R 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100 0 0 0\n"
        stat_file.write_text(stat_line, encoding="utf-8")
        stat_file.chmod(0o000)

        try:
            scanned = self.collector.scan_processes()
            found_pids = [s.pid for s in scanned]
            self.assertIn(201, found_pids)
            self.assertNotIn(202, found_pids)
        finally:
            stat_file.chmod(0o644)

    def test_pid_reuse_safety_and_generation_counter(self) -> None:
        """Assert PID reuse detection resets delta history and prevents misattribution."""
        # 1. First process at PID 800 with starttime=1000
        self._setup_mock_process(800, comm="old-worker", utime=100, stime=50, starttime_ticks=1000)
        res1 = self.collector.scan_processes()
        self.assertEqual(len(res1), 1)
        self.assertEqual(res1[0].comm, "old-worker")
        self.assertEqual(res1[0].starttime_ticks, 1000)
        self.assertEqual(self.collector._process_starttimes[800], 1000)

        # Establish CPU delta history
        self.collector.calculate_cpu_percent(800, 1500, current_time=100.0)

        # 2. Process exits and PID 800 is reused by a new process with starttime=5000
        self._setup_mock_process(800, comm="new-harness", utime=10, stime=5, starttime_ticks=5000)
        res2 = self.collector.scan_processes()
        self.assertEqual(len(res2), 1)
        self.assertEqual(res2[0].comm, "new-harness")
        self.assertEqual(res2[0].starttime_ticks, 5000)
        self.assertEqual(self.collector._process_starttimes[800], 5000)
        # CPU percent should be 0.0 because history was reset on PID reuse
        self.assertEqual(res2[0].attributes.cpu_percent, 0.0)

    def test_pid_reuse_race_during_scan_sweep(self) -> None:
        """Assert PID reuse race during attribute collection is discarded."""
        self._setup_mock_process(900, comm="race-worker", starttime_ticks=1000)
        original_read_stat = self.proc_reader.read_stat
        call_count = [0]

        def mutating_read_stat(pid: int) -> Optional[ProcStat]:
            res = original_read_stat(pid)
            if pid == 900 and res is not None:
                call_count[0] += 1
                if call_count[0] > 1:
                    # Return mutated starttime on second read (verifying race check)
                    return ProcStat(
                        pid=res.pid, comm="mutated", state=res.state, ppid=res.ppid,
                        pgrp=res.pgrp, session=res.session, utime_ticks=res.utime_ticks,
                        stime_ticks=res.stime_ticks, cutime_ticks=res.cutime_ticks,
                        cstime_ticks=res.cstime_ticks, starttime_ticks=999999,
                        vsize_bytes=res.vsize_bytes, rss_pages=res.rss_pages,
                        exit_code_raw=res.exit_code_raw
                    )
            return res

        self.proc_reader.read_stat = mutating_read_stat
        scanned = self.collector.scan_processes()
        # Process 900 should be rejected because starttime changed mid-scan
        self.assertEqual(scanned, [])

    def test_integration_child_process_15char_truncated_comm(self) -> None:
        """Assert scanner correctly identifies processes with 15-char comm names (TASK_COMM_LEN limit)."""
        self._setup_mock_process(333, comm="node-MainThread", exe_target="/usr/bin/node")
        scanned = self.collector.scan_processes()
        found = next((s for s in scanned if s.pid == 333), None)
        self.assertIsNotNone(found)
        assert found is not None
        self.assertEqual(found.comm, "node-MainThread")
        self.assertEqual(len(found.comm), 15)
        self.assertEqual(found.exe_basename, "node")

    def test_continuous_scan_yielding(self) -> None:
        """Assert continuous_scan yields batches and sleeps between sweeps without busy looping."""
        self._setup_mock_process(111, comm="test-agent")
        yielded_batches = []
        callback_calls = []

        for batch in self.collector.continuous_scan(
            interval_s=0.01,
            max_iterations=3,
            yield_callback=lambda b: callback_calls.append(len(b)),
        ):
            yielded_batches.append(batch)

        self.assertEqual(len(yielded_batches), 3)
        self.assertEqual(len(callback_calls), 3)
        self.assertTrue(all(len(b) == 1 and b[0].pid == 111 for b in yielded_batches))

    def test_output_conforms_to_frozen_allowlist(self) -> None:
        """Assert scanner output strictly conforms to P1-1's frozen allowlisted models."""
        self._setup_mock_process(444, comm="claude", utime=300, stime=100, rss_pages=1024, exe_target="/bin/claude")
        scanned = self.collector.scan_processes()
        self.assertEqual(len(scanned), 1)
        proc_record = scanned[0]

        # 1. BoundedProcessAttributes check
        attrs_dict = proc_record.attributes.to_dict(include_extended=True)
        allowlisted_attr_keys = {
            "health_state", "cpu_time_ms", "resident_memory_bytes",
            "exit_code", "restart_count", "cpu_percent", "pid", "ppid"
        }
        self.assertTrue(set(attrs_dict.keys()).issubset(allowlisted_attr_keys))

        # 2. ProcessInfo wire model check
        info = self.collector.to_process_info(proc_record)
        self.assertIsNotNone(info)
        assert info is not None
        info_dict = info.to_dict()
        self.assertEqual(set(info_dict.keys()), {"pid", "ppid", "comm", "rss_bytes", "cpu_ticks"})
        self.assertEqual(info_dict["pid"], 444)
        self.assertEqual(info_dict["comm"], "claude")
        self.assertEqual(info_dict["rss_bytes"], 1024 * 4096)
        self.assertEqual(info_dict["cpu_ticks"], 400)

    def test_integration_real_child_process_discovery_latency(self) -> None:
        """Integration test proving <2s discovery latency against real spawned child processes."""
        cmd = [sys.executable, "-c", "import time; time.sleep(3)"]
        proc = subprocess.Popen(cmd)
        try:
            real_collector = ProcessTelemetryCollector(proc_reader=ProcReader(proc_root="/proc"))
            start_t = time.perf_counter()
            scanned = real_collector.scan_processes(max_pids=None)
            elapsed = time.perf_counter() - start_t

            found = next((s for s in scanned if s.pid == proc.pid), None)
            self.assertIsNotNone(found, f"Real child PID {proc.pid} not found in scan")
            assert found is not None
            self.assertEqual(found.pid, proc.pid)
            self.assertLess(elapsed, 2.0, f"Discovery latency {elapsed:.3f}s exceeded 2.0s KPI budget")
            self.assertGreater(found.attributes.resident_memory_bytes, 0)
            self.assertEqual(found.attributes.health_state, HealthState.RUNNING)
        finally:
            proc.terminate()
            proc.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
