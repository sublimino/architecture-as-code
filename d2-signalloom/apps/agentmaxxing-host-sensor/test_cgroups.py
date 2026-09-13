"""Unit tests for Linux cgroups v2 reader."""
from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cgroups import CgroupCpuStat, CgroupMetrics, CgroupV2Reader
except (ImportError, ValueError):
    from cgroups import CgroupCpuStat, CgroupMetrics, CgroupV2Reader


class CgroupV2ReaderTests(unittest.TestCase):
    """Test suite for cgroups v2 metrics reading."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_cgroup_root = Path(self.temp_dir.name) / "cgroup"
        self.mock_proc_root = Path(self.temp_dir.name) / "proc"
        self.mock_cgroup_root.mkdir(parents=True, exist_ok=True)
        self.mock_proc_root.mkdir(parents=True, exist_ok=True)
        self.reader = CgroupV2Reader(cgroup_root=self.mock_cgroup_root)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_read_cpu_stat(self) -> None:
        unit_dir = self.mock_cgroup_root / "system.slice" / "agent.service"
        unit_dir.mkdir(parents=True, exist_ok=True)
        (unit_dir / "cpu.stat").write_text(
            "usage_usec 12500000\nuser_usec 8000000\nsystem_usec 4500000\nnr_periods 0\n",
            encoding="utf-8",
        )

        cpu_stat = self.reader.read_cpu_stat(unit_dir)
        self.assertIsNotNone(cpu_stat)
        assert cpu_stat is not None
        self.assertEqual(cpu_stat.usage_usec, 12500000)
        self.assertEqual(cpu_stat.user_usec, 8000000)
        self.assertEqual(cpu_stat.system_usec, 4500000)
        self.assertEqual(cpu_stat.cpu_time_ms, 12500)

    def test_read_memory_current(self) -> None:
        unit_dir = self.mock_cgroup_root / "system.slice" / "agent.service"
        unit_dir.mkdir(parents=True, exist_ok=True)
        (unit_dir / "memory.current").write_text("67108864\n", encoding="utf-8")

        mem = self.reader.read_memory_current(unit_dir)
        self.assertEqual(mem, 67108864)

    def test_read_pids_current(self) -> None:
        unit_dir = self.mock_cgroup_root / "system.slice" / "agent.service"
        unit_dir.mkdir(parents=True, exist_ok=True)
        (unit_dir / "pids.current").write_text("4\n", encoding="utf-8")

        pids = self.reader.read_pids_current(unit_dir)
        self.assertEqual(pids, 4)

    def test_resolve_cgroup_path_for_pid(self) -> None:
        pid_dir = self.mock_proc_root / "100"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "cgroup").write_text(
            "0::/system.slice/agentmaxxing-agent.service\n",
            encoding="utf-8",
        )
        target_cgroup = self.mock_cgroup_root / "system.slice" / "agentmaxxing-agent.service"
        target_cgroup.mkdir(parents=True, exist_ok=True)

        resolved = self.reader.resolve_cgroup_path_for_pid(100, proc_root=self.mock_proc_root)
        self.assertIsNotNone(resolved)
        self.assertEqual(resolved, target_cgroup)

    def test_read_metrics_aggregate(self) -> None:
        unit_dir = self.mock_cgroup_root / "test.slice"
        unit_dir.mkdir(parents=True, exist_ok=True)
        (unit_dir / "cpu.stat").write_text("usage_usec 2000000\n", encoding="utf-8")
        (unit_dir / "memory.current").write_text("1048576\n", encoding="utf-8")
        (unit_dir / "pids.current").write_text("1\n", encoding="utf-8")

        metrics = self.reader.read_metrics(unit_dir)
        self.assertIsNotNone(metrics.cpu_stat)
        self.assertEqual(metrics.cpu_stat.cpu_time_ms, 2000)
        self.assertEqual(metrics.memory_current_bytes, 1048576)
        self.assertEqual(metrics.pids_current, 1)

    def test_missing_cgroup_returns_none(self) -> None:
        nonexistent = self.mock_cgroup_root / "does-not-exist"
        self.assertIsNone(self.reader.read_cpu_stat(nonexistent))
        self.assertIsNone(self.reader.read_memory_current(nonexistent))
        self.assertIsNone(self.reader.read_pids_current(nonexistent))


if __name__ == "__main__":
    unittest.main()
